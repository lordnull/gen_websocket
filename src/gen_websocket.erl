%% @doc A websocket is, conceptually, like a tcp socket, therefore it
%% should be treated as one. Use this as you would use gen_tcp, and you
%% will know joy.

-module(gen_websocket).
-behavior(gen_fsm).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-else.
-define(debugFmt(_Fmt, _Args), ok).
-define(debugMsg(_Msg), ok).
-endif.

-define(OPCODES, [{continuation, 0}, {text, 1}, {binary, 2}, {close, 8},
	{ping, 9}, {pong, 10} ] ).

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

send(Socket, Msg) ->
	send(Socket, Msg, text).

send(Socket, Msg, Type) ->
	gen_fsm:sync_send_all_state_event(Socket, {send, Type, Msg}).

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
	?debugMsg("gen_fsm init"),
	Before = now(),
	case http_uri:parse(Url, [{scheme_defaults, [{ws, 80}, {wss, 443}]}]) of
		{ok, {WsProtocol, _Auth, Host, Port, Path, Query}} ->
			?debugFmt("From the url ~p I got host ~p, port ~p, and path ~p", [Url, Host, Port, Path]),
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

handle_event(Event, Statename, State) ->
	?debugFmt("handling event ~p", [Event]),
	{next_state, Statename, State}.

handle_sync_event({send, Type, Msg}, From, Statename, State) when Statename =:= active; Statename =:= active_once; Statename =:= passive ->
	?debugFmt("A send event of type ~p for msg ~p", [Type, Msg]),
	#state{transport = Trans, socket = Socket} = State,
	Data = encode(Type, Msg),
	Reply = Trans:send(Socket, Data),
	{reply, Reply, Statename, State};

handle_sync_event(Event, _From, Statename, State) ->
	?debugFmt("handling sync event ~p in state ~p", [Event, Statename]),
	{reply, {error, nyi}, Statename, State}.

handle_info({TData, Socket, Data}, recv_handshake, {#state{transport_data = TData, socket = Socket} = State, Timeout, From, Before}) ->
	Buffered = State#state.data_buffer,
	Buffer = <<Buffered/binary, Data/binary>>,
	?debugMsg("socket info in recv_handshake"),
	case re:run(Buffer, ".*\\r\\n\\r\\n") of
		{match, _} ->
			Key = State#state.key,
			ExpectedBack = base64:encode(crypto:sha(<<Key/binary, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>)),
			RegEx = ".*[s|S]ec-[w|W]eb[s|S]ocket-[a|A]ccept: (.*)\\r\\n.*",
			case re:run(Buffer, RegEx, [{capture, [1], binary}]) of
				{match, [ExpectedBack]} ->
					gen_fsm:reply(From, {ok, self()}),
					socket_setopts(State, [{active, once}]),
					{next_state, State#state.mode, State#state{data_buffer = Buffer}};
				_Else ->
					gen_fsm:reply(From, {error, key_mismatch}),
					{stop, normal, State}
			end;
		_NoMatch ->
			socket_setopts(State, [{active, once}]),
			After = now(),
			Timeout2 = timeleft(Timeout, Before, After),
			{next_state, recv_handshake, {State#state{data_buffer = Buffer}, Timeout2, From}, Timeout2}
	end;
	
handle_info(Info, Statename, State) ->
	?debugFmt("random message~n"
		"message: ~p~n"
		"statename: ~p~n"
		"state: ~p", [Info, Statename, State]),
	{next_state, Statename, State}.

terminate(_Why, _Statename, _State) ->
	?debugMsg("bing"),
	ok.

%% gen fsm states

init(start, From, {State, Timeout}) ->
	?debugMsg("Start message while in init state"),
	Before = now(),
	{Transport, MaybeSocket} = raw_socket_connect(State, Timeout),
	case MaybeSocket of
		{ok, Socket} ->
			State2 = State#state{socket = Socket, transport = Transport},
			State3 = set_socket_atoms(Transport, State2),
			After = now(),
			Timeleft = timeleft(Before, After, Timeout),
			Error = {stop, normal, {error, timeout}, {State3, Timeout}},
			Ok = {next_state, recv_handshake, {State3, Timeleft, From}, 0},
			if_timeleft(Timeout, Ok, Error)
	end.

init(_Msg, State) ->
	?debugMsg("bing"),
	{next_state, init, State}.

recv_handshake(_Msg, _From, State) ->
	?debugMsg("bing"),
	{reply, {error, nyi}, recv_handshake, State}.

recv_handshake(timeout, {State, Timeleft, From}) ->
	?debugMsg("timeout while in recv handshake, sending reqeust"),
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
	ok = Transport:send(Socket, Handshake),
	socket_setopts(Transport, Socket, [{active, once}]),
	After = now(),
	Remaining = timeleft(Before, After, Timeleft),
	Ok = {next_state, recv_handshake, {State, Remaining, From, now()}, Remaining},
	Err = fun() ->
		gen_fsm:reply(From, {error, timeout}),
		{stop, normal, {State, Timeleft, From}}
	end,
	if_timeleft(Remaining, Ok, Err);

recv_handshake(timeout, State) ->
	?debugMsg("bing"),
	{_WsSocket, _Timeleft, From, _Buffer} = State,
	gen_fsm:reply(From, {error, timeout}),
	{stop, normal, State}.

active(_Msg, _From, State) ->
	?debugMsg("bing"),
	{reply, {error, nyi}, active, State}.

active(_Msg, State) ->
	?debugMsg("bing"),
	{next_state, active, State}.

active_once(_Msg, _From, State) ->
	?debugMsg("bing"),
	{reply, {error, nyi}, active_once, State}.

active_once(_Msg, State) ->
	?debugMsg("bing"),
	{next_state, active_once, State}.

passive(_Msg, _From, State) ->
	?debugMsg("bing"),
	{reply, {error, nyi}, passive, State}.

passive(_Msg, State) ->
	?debugMsg("bing"),
	{next_state, passive, State}.

closed(_Msg, _From, State) ->
	?debugMsg("bing"),
	{reply, {error, nyi}, closed, State}.

closed(_Msg, State) ->
	?debugMsg("bing"),
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

opcode_from_name(Name) ->
	proplists:get_value(Name, ?OPCODES).

opcode_to_name(Value) ->
	lists:keyfind(Value, 2, ?OPCODES).

encode(Type, IoList) ->
	Opcode = opcode_from_name(Type),
	Len = payload_length(iolist_size(IoList)),
	Payload = iolist_to_binary(IoList),
	{Key, MaskedPayload} = mask_payload(Payload),
	?debugFmt("do they match in size? ~p", [bit_size(MaskedPayload) == bit_size(Payload)]),
	?debugFmt("compare original to masked:~n"
		"    Original (~p): ~p~n"
		"    Masked (~p): ~p", [bit_size(Payload), Payload, bit_size(MaskedPayload), MaskedPayload]),
	Header = <<1:1, 0:3, Opcode:4, 1:1, Len/bits, Key/bits>>, 
	<<Header/binary, MaskedPayload/binary>>.


mask_payload(Payload) ->
	Key = crypto:rand_bytes(4),
	<<Mask:32>> = Key,
	Masked = mask_payload(Mask, Payload),
	{Key, Masked}.

mask_payload(Key, Bin) ->
	mask_payload(Key, Bin, <<>>).

mask_payload(_Key, <<>>, Acc) ->
	?debugMsg("empty binary"),
	Acc;
mask_payload(Key, Bits, Acc) when bit_size(Bits) < 32 ->
	?debugFmt("Bits left: ~p", [Bits]),
	SizeToMask = bit_size(Bits),
	KeyMaskLeft = 32 - SizeToMask,
	<<SubKey:SizeToMask, _:KeyMaskLeft>> = <<Key:32>>,
	<<B:SizeToMask>> = Bits,
	B2 = B bxor SubKey,
	<<Acc/binary, B2:SizeToMask>>;
mask_payload(Key, <<B:32, Rest/binary>>, Acc) ->
	?debugFmt("Nom a bit: ~p", [B]),
	B2 = B bxor Key,
	Acc2 = <<Acc/binary, B2:32>>,
	mask_payload(Key, Rest, Acc2).


payload_length(N) when N =< 125 ->
	<<N:7>>;
payload_length(N) when N =< 65535 ->
	<<126:7, N:16>>;
payload_length(N) when N =< 16#7fffffffffffffff ->
	<<127:7, N:64>>.
