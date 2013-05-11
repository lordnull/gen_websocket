%% @doc A websocket is, conceptually, like a tcp socket, therefore it
%% should be treated as one. Use this as you would use gen_tcp, and you
%% will know joy.

-module(gen_websocket).
-behavior(gen_fsm).

% gen fsm states
-export([
	init/2, init/3,
	recv_handshake/2, recv_handshake/3,
	passive/2, passive/3,
	active/2, active/3,
	active_once/2, active_once/3,
	closed/2, closed/3
]).
% gen_fsm others
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3, 
	terminate/3, code_change/4]).
% public api
-export([connect/2, connect/3, send/2, recv/1, recv/2,
	controlling_process/2, close/1, shutdown/2, setopts/2]).

-type mode() :: 'passive' | 'once' | 'active'.

-record(state, {
	owner = self() :: pid(),
	passive_from,
	protocol,
	socket,
	transport,
	transport_data,
	transport_close,
	transport_error,
	host,
	port,
	path,
	key = base64:encode(crypto:rand_bytes(16)),
	data_buffer = <<>>,
	fame_buffer = [],
	max_frame_buffer = 3,
	mode = passive :: mode()
}).

%% public api
connect(Url, Opts) ->
	connect(Url, Opts, infinity).

connect(Url, Opts, Timeout) ->
	Self = self(),
	case gen_fsm:start(?MODULE, [Self, Url, Opts, Timeout], []) of
		{ok, Pid} ->
			gen_fsm:sync_send_event(Pid, start, infinity);
		Else ->
			Else
	end.

send(_Socket, _Msg) ->
	{error, nyi}.

recv(Socket) ->
	recv(Socket, infinity).

recv(_Socket, _Timeout) ->
	{error, nyi}.

controlling_process(_Socket, _NewOwner) ->
	{error, nyi}.

close(_Socket) ->
	{error, nyi}.

shutdown(_Socket, _How) ->
	{error, nyi}.

setopts(_Socket, _Opts) ->
	{error, nyi}.

%% gen_fsm api
init([Controller, Url, _Opts, Timeout]) ->
	Before = now(),
	case http_uri:parse(Url, [{scheme_defaults, [{ws, 80}, {wss, 443}]}]) of
		{ok, {WsProtocol, _Auth, Host, Port, Path, Query}} ->
			State = #state{ owner = Controller, host = Host, port = Port,
				path = Path ++ Query, protocol = WsProtocol},
			After = now(),
			TimeLeft = timeleft(Before, After, Timeout),
			if
				TimeLeft > 0 ->
					{ok, init, {State, TimeLeft}};
				true ->
					{error, timeout}
			end;
		Else ->
			Else
	end.

code_change(_OldVan, StateName, State, _Extra) ->
	{ok, StateName, State}.

handle_event(_Event, Statename, State) ->
	{next_state, Statename, State}.

handle_sync_event(_Event, _From, Statename, State) ->
	{reply, {error, nyi}, Statename, State}.

handle_info(_Info, Statename, State) ->
	{next_state, Statename, State}.

terminate(_Why, _Statename, _State) ->
	ok.

%% gen fsm states

init(start, From, {State, Timeout}) ->
	Before = now(),
	{Transport, MaybeSocket} = raw_socket_connect(State, Timeout),
	case MaybeSocket of
		{ok, Socket} ->
			State2 = #state{socket = Socket, transport = Transport},
			State3 = set_socket_atoms(Transport, State2),
			After = now(),
			Timeleft = timeleft(Before, After, Timeout),
			Error = {stop, normal, {error, timeout}, {State3, Timeout}},
			Ok = {next_state, recv_handshake, {State3, Timeleft, From}, 0},
			if_timeleft(Timeout, Ok, Error)
	end.

init(_Msg, State) ->
	{next_state, init, State}.

recv_handshake(_Msg, _From, State) ->
	{reply, {error, nyi}, recv_handshake, State}.

recv_handshake(timeout, {State, Timeleft, From}) ->
	Before = now(),
	#state{transport = Transport, socket = Socket, key = Key,
		protocol = Protocol, host = Host, path = Path} = State,
	Handshake = [<<"GET ">>, Path,
		<<" HTTP/1.1\r\n"
			"Host: ">>, Host, <<"\r\n"
			"Upgrade: Websocket\r\n"
			"Connection: Upgrade\r\n"
			"Sec-WebSocket-Key: ">>, Key, <<"\r\n"
			"Origin: ">>, atom_to_binary(Protocol, utf8), <<"://">>, Host, <<"\r\n"
			"Sec-WebSocket-Protocol: \r\n"
			"Sec-WebSocket-Version: 13\r\n"
			"\r\n">>],
	Transport:send(Socket, Handshake),
	socket_setopts(Transport, Socket, [{active, once}]),
	After = now(),
	Remaining = timeleft(Before, After, Timeleft),
	Ok = {next_state, recv_handshake, {State, Remaining, From, <<>>, now()}, Remaining},
	Err = fun() ->
		gen_fsm:reply(From, {error, timeout}),
		{stop, normal, {State, Timeleft, From}}
	end,
	if_timeleft(Remaining, Ok, Err);

recv_handshake(timeout, State) ->
	{_WsSocket, _Timeleft, From, _Buffer} = State,
	gen_fsm:reply(From, {error, timeout}),
	{stop, normal, State};

recv_handshake({TransportData, Socket, Data}, {#state{transport_data = TransportData, socket = Socket} = WsSocket, Timeout, From, Buffer, Before} = State) ->
	case re:run(Buffer, ".*\\r\\n\\r\\n") of
		{match, _} ->
			Key = WsSocket#state.key,
			ExpectedBack = base64:encode(crypto:sha(<<Key/binary, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>)),
			RegEx = ".*[s|S]ec-[w|W]eb[s|S]ocket-[a|A]ccept: (.*)\\r\\n.*",
			case re:run(Buffer, RegEx, [{capture, [1], binary}]) of
				{match, [ExpectedBack]} ->
					gen_fsm:reply(From, {ok, self()}),
					socket_setopts(State, [{active, once}]),
					{next_state, State#state.mode, State};
				_Else ->
					gen_fsm:reply(From, {error, key_mismatch}),
					{stop, normal, State}
			end;
		_NoMatch ->
			socket_setopts(WsSocket#state.transport, WsSocket#state.socket, [{active, once}]),
			After = now(),
			Buffer2 = <<Buffer/binary, Data/binary>>,
			Timeout2 = timeleft(Timeout, Before, After),
			{next_state, recv_handshake, {WsSocket, Timeout2, From, Buffer2, After, Timeout2}, Timeout2}
	end.

active(_Msg, _From, State) ->
	{reply, {error, nyi}, active, State}.

active(_Msg, State) ->
	{next_state, active, State}.

active_once(_Msg, _From, State) ->
	{reply, {error, nyi}, active_once, State}.

active_once(_Msg, State) ->
	{next_state, active_once, State}.

passive(_Msg, _From, State) ->
	{reply, {error, nyi}, passive, State}.

passive(_Msg, State) ->
	{next_state, passive, State}.

closed(_Msg, _From, State) ->
	{reply, {error, nyi}, closed, State}.

closed(_Msg, State) ->
	{next_state, closed, State}.

% internal functions

raw_socket_connect(State, Timeout) ->
	#state{protocol = Proto, host = Host, port = Port} = State,
	raw_socket_connect(Proto, Host, Port, Timeout).

raw_socket_connect(ws, Host, Port, Timeout) ->
	Options = [binary, {active, false}, {packet, 0}],
	MaybeSocket = gen_tcp:connect(Host, Port, Options, Timeout),
	{gen_tcp, MaybeSocket};
raw_socket_connect(wss, Host, Port, Timeout) ->
	Options = [{mode, binary}, {verify, verify_none}, {active, false},
		{packet, 0}],
	MaybeSocket = ssl:connect(Host, Port, Options, Timeout),
	{ssl, MaybeSocket}.

socket_setopts(State, Opts) ->
	#state{transport = T, socket = S} = State,
	socket_setopts(T, S, Opts).

socket_setopts(gen_tcp, Socket, Opts) ->
	inet:setopts(Socket, Opts);
socket_setopts(ssl, Socket, Opts) ->
	ssl:setopts(Socket, Opts).

set_socket_atoms(ssl, WsSocket) ->
	WsSocket#state{
		transport_data = ssl,
		transport_close = ssl_closed,
		transport_error = ssl_error};
set_socket_atoms(gen_tcp, WsSocket) ->
	WsSocket#state{
		transport_data = tcp,
		transport_close = tcp_closed,
		transport_error = tcp_error}.

timeleft(_Before, _After, infinity) ->
	infinity;
timeleft(Before, After, Timeout) ->
	Dur = timer:now_diff(After, Before),
	Timeout - Dur.

if_timeleft(infinity, Ok, _Err) when is_function(Ok, 0) ->
	Ok();
if_timeleft(infinity, Ok, _Err) ->
	Ok;
if_timeleft(Time, Ok, _Err) when Time > 0, is_function(Ok, 0) ->
	Ok();
if_timeleft(Time, Ok, _Err) when Time > 0 ->
	Ok;
if_timeleft(_Time, _Ok, Err) when is_function(Err, 0) ->
	Err();
if_timeleft(_Time, _Ok, Err) ->
	Err.
