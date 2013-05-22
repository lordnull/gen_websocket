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
	frame_buffer = [],
	max_frame_buffer = 3,
	mode = passive :: mode(),
	passive_from = undefined,
	passive_tref = undefined
}).

-record(raw_frame, {
	fin = 0,
	opcode = 0,
	payload
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

recv(Socket, Timeout) ->
	gen_fsm:sync_send_event(Socket, {recv, Timeout}).

controlling_process(_Socket, _NewOwner) ->
	{error, nyi}.

close(_Socket) ->
	{error, nyi}.

shutdown(_Socket, _How) ->
	{error, nyi}.

setopts(Socket, Opts) ->
	gen_fsm:sync_send_all_state_event(Socket, {setopts, Opts}).

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

handle_sync_event({setopts, Opts}, _From, Statename, State) ->
	case verify_opts(Opts, Statename, State) of
		true ->
			{NextState, State2} = setopts_state_transition(Opts, Statename, State),
			{reply, ok, NextState, State2};
		false ->
			{reply, {error, badarg}, Statename, State}
	end;

handle_sync_event({setopts, [{active, Active} | Tail]}, From, Statename, State) ->
	case {Active, Statename} of
		{true, active} ->
			handle_sync_event({setopts, Tail}, From, Statename, State);
		{false, passive} ->
			handle_sync_event({setopts, Tail}, From, Statename, State);
		{once, active_once} ->
			handle_sync_event({setopts, Tail}, From, Statename, State);
		{true, _Old} ->
			handle_sync_event({setopts, Tail}, From, active, State);
		{false, _Old} ->
			handle_sync_event({setopts, Tail}, From, passive, State);
		{once, _Old} ->
			handle_sync_event({setopts, Tail}, From, active_once, State)
	end;

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
					{next_state, State#state.mode, State#state{data_buffer = <<>>}};
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

handle_info({TData, Socket, Data}, StateName, #state{transport_data = TData, socket = Socket} = State) when StateName =:= passive; StateName =:= active_once; StateName =:= active ->
	StateBuffer = State#state.data_buffer,
	Buffer = <<StateBuffer/binary, Data/binary>>,
	?debugFmt("got in me buffer: ~p", [Buffer]),
	case {decode_frames(Buffer, State), StateName} of
		{{ok, [], NewBuffer}, passive} ->
			State2 = State#state{data_buffer = NewBuffer},
			socket_setopts(State, [{active, once}]),
			{next_state, StateName, State2};
		{{ok, Frames, NewBuffer}, passive} when State#state.passive_from =:= undefined ->
			NewFrameBuffer = State#state.frame_buffer ++ Frames,
			if
				length(NewFrameBuffer) >= State#state.max_frame_buffer ->
					ok;
				true ->
					socket_setopts(State, [{active, once}])
			end,
			State2 = State#state{frame_buffer = NewFrameBuffer, data_buffer = NewBuffer},
			{next_state, StateName, State2};
		{{ok, [Frame | Frames], NewBuffer}, passive} ->
			gen_fsm:reply(State#state.passive_from, {ok, Frame}),
			case State#state.passive_tref of
				undefined ->
					ok;
				_ ->
					gen_fsm:cancel_timer(State#state.passive_tref)
			end,
			if
				length(Frames) >= State#state.frame_buffer ->
					ok;
				true ->
					socket_setopts(State, [{active, once}])
			end,
			State2 = State#state{frame_buffer = Frames, data_buffer = NewBuffer, passive_from = undefined, passive_tref = undefined},
			{next_state, StateName, State2};
		{{ok, Frames, NewBuffer}, active} ->
			Owner = State#state.owner,
			lists:map(fun(Frame) ->
				Owner ! {?MODULE, self(), Frame}
			end, Frames),
			socket_setopts(State, [{active, once}]),
			State2 = State#state{frame_buffer = [], data_buffer = NewBuffer},
			{next_state, StateName, State2};
		{{ok, [], NewBuffer}, active_once} ->
			State2 = State#state{data_buffer = NewBuffer},
			{next_state, StateName, State2};
		{{ok, [Frame | FrameBuffer], NewBuffer}, active_once} ->
			State#state.owner ! {?MODULE, self(), Frame},
			if
				length(FrameBuffer) >= State#state.max_frame_buffer ->
					ok;
				true ->
					socket_setopts(State, [{active, once}])
			end,
			State2 = State#state{frame_buffer = FrameBuffer, data_buffer = NewBuffer},
			{next_state, passive, State2};
		Error ->
			?debugFmt("Frame decode error: ~p", [Error]),
			{next_state, closed, State}
	end;

handle_info(Info, Statename, State) ->
	?debugFmt("random message~n"
		"    message: ~p~n"
		"    statename: ~p~n"
		"    state: ~p", [Info, Statename, State]),
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

passive({recv, Timeout}, _From, #state{frame_buffer = Frames} = State) when length(Frames) > 0 ->
	[Frame | Tail] = Frames,
	if
		length(Tail) < State#state.max_frame_buffer ->
			socket_setopts(State, [{active, once}]);
		true ->
			ok
	end,
	{reply, {ok, Frame}, passive, State#state{frame_buffer = Frames}};

passive({recv, Timeout}, From, #state{passive_from = undefined} = State) ->
	Tref = case Timeout of
		infinity ->
			undefined;
		_ ->
			gen_fsm:start_timer(Timeout, recv_timeout)
	end,
	State2 = State#state{passive_from = From, passive_tref = Tref},
	{next_state, passive, State2};

passive({recv, Tiemout}, _From, State) ->
	{reply, {error, already_recv}, passive, State};

passive(Msg, From, State) ->
	?debugFmt("bad request from ~p: ~p", [From, Msg]),
	{reply, {error, bad_request}, passive, State}.

passive({timeout, Tref, recv_timeout}, #state{passive_tref = Tref} = State) ->
	gen_fsm:reply(State#state.passive_from, {error, timeout}),
	State2 = State#state{passive_tref = undefined, passive_from = undefined},
	{next_state, passive, State2};

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
	case lists:keyfind(Value, 2, ?OPCODES) of
		false ->
			undefined;
		{Atom, Value} ->
			Atom
	end.

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

verify_opts([], _StateName, _State) ->
	true;
verify_opts([{active, Activeness} | Tail], StateName, State) ->
	if
		Activeness ->
			verify_opts(Tail, StateName, State);
		not Activeness ->
			verify_opts(Tail, StateName, State);
		Activeness =:= once ->
			verify_opts(Tail, StateName, State);
		true ->
			false
	end.

setopts_state_transition(Opts, Statename, State) ->
	GetActiveFun = fun
		({active, true}, _) ->
			active;
		({active, once}, _) ->
			active_once;
		({active, false}, _) ->
			passive;
		(_, Active) ->
			Active
	end,
	Active = lists:foldl(GetActiveFun, Statename, Opts),
	case Active of
		Statename ->
			{Statename, State};
		passive ->
			{passive, State};
		active_once when length(State#state.frame_buffer) > 0 ->
			[Frame | Tail] = State#state.frame_buffer,
			Owner = State#state.owner,
			Owner ! {?MODULE, self(), Frame},
			State2 = State#state{frame_buffer =  Tail},
			{passive, State2};
		active_once ->
			{active, State};
		active ->
			Buffer = State#state.frame_buffer,
			Owner = State#state.owner,
			[Owner ! {?MODULE, self(), Frame} || Frame <- Buffer],
			socket_setopts(State, [{active, once}]),
			State2 = State#state{frame_buffer = []},
			{active, State2}
	end.

decode_frames(Binary, State) ->
	decode_frames(Binary, State, []).

decode_frames(<<Fin:1, 0:3, Opcode:4, 0:1, Len:7, Rest/bits>>, State, Acc) when Len < 126 ->
	<<Payload:Len/binary, Rest2/bits>> = Rest,
	Frame = #raw_frame{fin = Fin, opcode = Opcode, payload = Payload},
	Acc2 = [Frame | Acc],
	decode_frames(Rest2, State, Acc2);
decode_frames(<<Fin:1, 0:3, Opcode:4, 0:1, 126:7, Len:16, Rest/bits>>, State, Acc) when Len > 125, Opcode < 8 ->
	<<Payload:Len/binary, Rest2/bits>> = Rest,
	Frame = #raw_frame{fin = Fin, opcode = Opcode, payload = Payload},
	Acc2 = [Frame | Acc],
	decode_frames(Rest2, State, Acc2);
decode_frames(<<Fin:1, 0:3, Opcode:4, 0:1, 127:7, Len:63, Rest/bits>>, State, Acc) when Len > 16#ffff, Opcode < 8 ->
	<<Payload:Len/binary, Rest2/bits>> = Rest,
	Frame = #raw_frame{fin = Fin, opcode = Opcode, payload = Payload},
	Acc2 = [Frame | Acc],
	decode_frames(Rest2, State, Acc2);
decode_frames(Rest, _State, Acc) ->
	Acc2 = lists:reverse(Acc),
	Frames = collapse_continuations(Acc2),
	{ok, Frames, Rest}.

collapse_continuations(Frames) ->
	collapse_continuations(Frames, undefined, <<>>, []).

collapse_continuations([], _Opcode, _DataBuffer, Acc) ->
	lists:reverse(Acc);
collapse_continuations([#raw_frame{fin = 0, opcode = 0, payload = Bin}| Tail], Type, Data, Acc) ->
	collapse_continuations(Tail, Type, <<Data/binary, Bin/binary>>, Acc);
collapse_continuations([#raw_frame{fin = 1, opcode = 0, payload = Bin} | Tail], Type, Data, Acc) ->
	Data2 = <<Data/binary, Bin/binary>>,
	Acc2 = [{Type, Data2} | Acc],
	collapse_continuations(Tail, undefined, <<>>, Acc2);
collapse_continuations([#raw_frame{fin = 0, opcode = Op, payload = Bin} | Tail], _Type, _Data, Acc) ->
	Opname = opcode_to_name(Op),
	collapse_continuations(Tail, Opname, Bin, Acc);
collapse_continuations([#raw_frame{opcode = Op, payload = Bin} | Tail], _Type, _Data, Acc) ->
	Opname = opcode_to_name(Op),
	Acc2 = [{Opname, Bin} | Acc],
	collapse_continuations(Tail, undefined, <<>>, Acc2).
