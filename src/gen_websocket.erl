%% @doc A websocket is, conceptually, like a tcp socket, therefore it
%% should be treated as one. Use this as you would use gen_tcp, and you
%% will know joy.

-module(gen_websocket).
-behavior(gen_fsm).

%-ifdef(TEST).
%-include_lib("eunit/include/eunit.hrl").
%-else.
%-define(debugFmt(_Fmt, _Args), ok).
%-define(debugMsg(_Msg), ok).
%-endif.

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
	passive_tref = undefined,
	on_owner_exit = nothing,
	owner_monref
}).

-record(raw_frame, {
	fin = 0,
	opcode = 0,
	payload
}).

-record(init_opts, {
	mode = passive,
	on_owner_exit = nothing
}).

-type active_opt() :: {'active' | mode()}.
-type connect_opt() :: active_opt().
-type connect_opts() :: [connect_opt()].
-type url() :: binary().
-opaque websocket() :: pid().
-type message_type() :: 'text' | 'binary'.
-type frame() :: {message_type(), binary()}.

-export_type([websocket/0]).

%% public api
%% @doc Same as connect/3 with an infinite timeout. @see connect/3
-spec connect(Url :: url(), Opts :: connect_opts()) -> {'ok', websocket()}.
connect(Url, Opts) ->
	connect(Url, Opts, infinity).

%% @doc Connect to the given websocket server. The timeout takes into
%% account the handshake as well.
%% Options:
%% <dl>
%%     <dt>active</dt><dd>true, false, or once. When true, a message
%% is sent to the owner process when a new frame is available. When
%% once, when a frame is available a message is sent to the owner
%% process, then the socket is set to `{active, false}', also known as
%% passive. When in passive mode, recv/1,2 are used to retreive
%% frames.</dd>
%% </dl>
%%
%% When in active mode, the message send is of form:
%%     `{gen_websocket, websocket(), frame()}'
-spec connect(Url :: url(), Opts :: connect_opts(), Timeout :: timeout()) -> {'ok', websocket()}.
connect(Url, Opts, Timeout) ->
	case verify_opts(Opts) of
		false ->
			{error, badarg};
		true ->
			Self = self(),
			case gen_fsm:start(?MODULE, [Self, Url, Opts, Timeout], []) of
				{ok, Pid} ->
					gen_fsm:sync_send_event(Pid, start, infinity);
				Else ->
					Else
			end
	end.

%% @doc Send a message as text. @see send/3.
-spec send(Socket :: websocket(), Msg :: binary()) -> 'ok'.
send(Socket, Msg) ->
	send(Socket, Msg, text).

%% @doc Send a message as the given type.
-spec send(Socket :: websocket(), Msg :: binary(), Type :: message_type()) -> 'ok'.
send(Socket, Msg, Type) ->
	gen_fsm:sync_send_all_state_event(Socket, {send, Type, Msg}).

%% @doc recv/2 with an infinte timeout. @see recv/2
-spec recv(Socket :: websocket()) -> {'ok', frame()}.
recv(Socket) ->
	recv(Socket, infinity).

%% @doc Get a single frame from the socket, giving up after the timeout.
-spec recv(Socket :: websocket(), Timeout :: timeout()) -> {'ok', frame()} | {'error', 'timeout'}.
recv(Socket, Timeout) ->
	gen_fsm:sync_send_event(Socket, {recv, Timeout}).

%% @doc set the controlling process to a new owner. Can only suceede if
%% called from the current owner.
-spec controlling_process(Socket :: websocket(), NewOwner :: pid()) -> 'ok' | {'error', 'not_owner'}.
controlling_process(Socket, NewOwner) ->
	gen_fsm:sync_send_all_state_event(Socket, {controlling_process, NewOwner}).

%% @doc Close the socket without exiting the process created on socket
%% connect.
-spec close(Socket :: websocket()) -> 'ok' | {'error', term()}.
close(Socket) ->
	gen_fsm:sync_send_event(Socket, close).

%% @doc Close the socket and shut it down with the given reason.
-spec shutdown(Socket :: websocket(), How :: term()) -> 'ok'.
shutdown(Socket, How) ->
	gen_fsm:send_event(Socket, {shutdown, How}).

%% @doc Set the given options on the given socket.
-spec setopts(Socket :: websocket(), Opts :: connect_opts()) -> 'ok'.
setopts(Socket, Opts) ->
	gen_fsm:sync_send_all_state_event(Socket, {setopts, Opts}).

%% @private
%% gen_fsm api
init([Controller, Url, Opts, Timeout]) ->
	OptsRec = build_opts(Opts),
	Before = now(),
	case http_uri:parse(Url, [{scheme_defaults, [{ws, 80}, {wss, 443}]}]) of
		{ok, {WsProtocol, _Auth, Host, Port, Path, Query}} ->
			State = #state{ owner = Controller, host = Host, port = Port,
				path = Path ++ Query, protocol = WsProtocol},
			After = now(),
			TimeLeft = timeleft(Before, After, Timeout),
			if
				TimeLeft > 0 ->
					{ok, init, {State, OptsRec, TimeLeft}};
				true ->
					{error, timeout}
			end;
		Else ->
			Else
	end.

%% @private
code_change(_OldVan, StateName, State, _Extra) ->
	{ok, StateName, State}.

%% @private
handle_event({shutdown, Why}, passive, #state{passive_from = From} = State) when From =/= undefined ->
	gen_fsm:reply(From, {error, shutdown}),
	{stop, Why, State};
handle_event({shutdown, Why}, _StateName, State) ->
	{stop, Why, State};

handle_event(Event, Statename, State) ->
	{next_state, Statename, State}.

%% @private
handle_sync_event(_Event, _From, closed, State) ->
	{reply, {error, closed}, closed, State};

handle_sync_event({controlling_process, NewOwner}, {Owner, _}, Statename, #state{owner = Owner} = State) ->
	erlang:demonitor(State#state.owner_monref, [flush]),
	MonRef = erlang:monitor(process, NewOwner),
	State2 = State#state{owner = NewOwner, owner_monref = MonRef},
	{reply, ok, Statename, State2};

handle_sync_event({controlling_process, _NewOwner}, _From, Statename, State) ->
	{reply, {error, not_owner}, Statename, State};

handle_sync_event({setopts, Opts}, _From, Statename, State) ->
	case verify_opts(Opts) of
		true ->
			OwnerExitFolder = fun
				({owner_exit, DoWhat}, _Acc) ->
					DoWhat;
				(_, Acc) ->
					Acc
			end,
			OnOwnerExit = lists:foldl(OwnerExitFolder, State#state.on_owner_exit, Opts),
			{NextState, State2} = setopts_state_transition(Opts, Statename, State),
			{reply, ok, NextState, State2#state{on_owner_exit = OnOwnerExit}};
		false ->
			{reply, {error, badarg}, Statename, State}
	end;

handle_sync_event({send, Type, Msg}, From, Statename, State) when Statename =:= active; Statename =:= active_once; Statename =:= passive ->
	#state{transport = Trans, socket = Socket} = State,
	Data = encode(Type, Msg),
	Reply = Trans:send(Socket, Data),
	{reply, Reply, Statename, State};

handle_sync_event(Event, _From, Statename, State) ->
	{reply, {error, nyi}, Statename, State}.

%% @private
handle_info({TData, Socket, Data}, recv_handshake, {#state{transport_data = TData, socket = Socket} = State, Timeout, Opts, From, Before}) ->
	Buffered = State#state.data_buffer,
	Buffer = <<Buffered/binary, Data/binary>>,
	case re:run(Buffer, ".*\\r\\n\\r\\n") of
		{match, _} ->
			Key = State#state.key,
			ExpectedBack = base64:encode(crypto:sha(<<Key/binary, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11">>)),
			RegEx = ".*[s|S]ec-[w|W]eb[s|S]ocket-[a|A]ccept: (.*)\\r\\n.*",
			case re:run(Buffer, RegEx, [{capture, [1], binary}]) of
				{match, [ExpectedBack]} ->
					gen_fsm:reply(From, {ok, self()}),
					socket_setopts(State, [{active, once}]),
					OwnerMon = erlang:monitor(process, element(1, From)),
					{next_state, Opts#init_opts.mode, State#state{data_buffer = <<>>, on_owner_exit = Opts#init_opts.on_owner_exit, owner_monref = OwnerMon}};
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
	case decode_frames(Buffer, State) of
		{ok, Frames, NewBuffer} ->
			?MODULE:StateName({decoded_frames, Frames, NewBuffer}, State);
		Error ->
			{next_state, closed, State}
	end;

handle_info({'DOWN', OwnerMon, process, Owner, Why}, StateName, #state{owner = Owner, owner_monref = OwnerMon, on_owner_exit = OnExit} = State) ->
	case OnExit of
		nothing ->
			{next_state, StateName, State};
		shutdown ->
			handle_event({shutdown, Why}, StateName, State);
		{shutdown, Reason} ->
			handle_event({shutdown, Reason}, StateName, State);
		close ->
			{reply, _Reply, NextState, State2} = ?MODULE:StateName(close, from, State),
			{next_state, NextState, State2}
	end;

handle_info(Info, Statename, State) ->
	{next_state, Statename, State}.

%% @private
terminate(_Why, _Statename, _State) ->
	ok.

%% gen fsm states

%% @private
init(start, From, {State, Opts, Timeout}) ->
	Before = now(),
	{Transport, MaybeSocket} = raw_socket_connect(State, Timeout),
	case MaybeSocket of
		{ok, Socket} ->
			State2 = State#state{socket = Socket, transport = Transport},
			State3 = set_socket_atoms(Transport, State2),
			After = now(),
			Timeleft = timeleft(Before, After, Timeout),
			Error = {stop, normal, {error, timeout}, {State3, Timeout}},
			Ok = {next_state, recv_handshake, {State3, Timeleft, Opts, From}, 0},
			if_timeleft(Timeout, Ok, Error)
	end;

init(close, _From, {State, _Opts, _Timeout}) ->
	{reply, ok, closed, State}.

init(_Msg, State) ->
	{next_state, init, State}.

%% @private
recv_handshake(close, _From, {State, _Timeout, _Opts, _OtherFrom}) ->
	#state{transport = T, socket = S} = State,
	T:close(S),
	{reply, ok, closed, State};

recv_handshake(_Msg, _From, State) ->
	{reply, {error, nyi}, recv_handshake, State}.

%% @private
recv_handshake(timeout, {State, Timeleft, Opts, From}) ->
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
	Ok = {next_state, recv_handshake, {State, Remaining, Opts, From, now()}, Remaining},
	Err = fun() ->
		gen_fsm:reply(From, {error, timeout}),
		{stop, normal, {State, Timeleft, From}}
	end,
	if_timeleft(Remaining, Ok, Err);

recv_handshake(timeout, State) ->
	{_WsSocket, _Timeleft, From, _Buffer} = State,
	gen_fsm:reply(From, {error, timeout}),
	{stop, normal, State}.

%% @private
active({recv, _Timeout}, _From, State) ->
	{reply, {error, not_passive}, active, State};

active(close, _From, State) ->
	#state{transport = T, socket = S} = State,
	T:close(S),
	{reply, ok, closed, State};

active(_Msg, _From, State) ->
	{reply, {error, nyi}, active, State}.

%% @private
active({decoded_frames, Frames, Buffer}, State) ->
	lists:map(fun(Frame) ->
		State#state.owner ! {?MODULE, self(), Frame}
	end, Frames),
	socket_setopts(State, [{active, once}]),
	State2 = State#state{frame_buffer = [], data_buffer = Buffer},
	{next_state, active, State2};

active(_Msg, State) ->
	{next_state, active, State}.

%% @private
active_once(close, _From, State) ->
	#state{transport = T, socket = S} = State,
	T:close(S),
	{reply, ok, closed, State};

active_once({recv, _Timeout}, _From, State) ->
	{reply, {error, not_passive}, active_once, State}.

%% @private
active_once({decoded_frames, [], Buffer}, State) ->
	State2 = State#state{data_buffer = Buffer},
	socket_setopts(State, [{active, once}]),
	{next_state, active_once, State2};

active_once({decoded_frames, [Frame | Frames], Buffer}, State) ->
	State#state.owner ! {?MODULE, self(), Frame},
	if
		length(Frames) >= State#state.max_frame_buffer ->
			ok;
		true ->
			socket_setopts(State, [{active, once}])
	end,
	State2 = State#state{frame_buffer = Frames, data_buffer = Buffer},
	{next_state, passive, State2};

active_once(_Msg, State) ->
	{next_state, active_once, State}.

%% @private
passive({recv, Timeout}, _From, #state{frame_buffer = Frames} = State) when length(Frames) > 0 ->
	[Frame | Tail] = Frames,
	if
		length(Tail) < State#state.max_frame_buffer ->
			socket_setopts(State, [{active, once}]);
		true ->
			ok
	end,
	{reply, {ok, Frame}, passive, State#state{frame_buffer = Tail}};

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

passive(close, _From, State) ->
	case State#state.passive_from of
		undefined ->
			ok;
		Waiting ->
			gen_fsm:reply(Waiting, {error, closed})
	end,
	case State#state.passive_tref of
		undefined ->
			ok;
		Tref ->
			gen_fsm:cancel_timer(Tref)
	end,
	#state{transport = T, socket = S} = State,
	T:close(S),
	State2 = State#state{passive_from = undefined, passive_tref = undefined},
	{reply, ok, closed, State2};

passive(Msg, From, State) ->
	{reply, {error, bad_request}, passive, State}.

%% @private
passive({timeout, Tref, recv_timeout}, #state{passive_tref = Tref} = State) ->
	gen_fsm:reply(State#state.passive_from, {error, timeout}),
	State2 = State#state{passive_tref = undefined, passive_from = undefined},
	{next_state, passive, State2};

passive({decoded_frames, [], Buffer}, State) ->
	socket_setopts(State, [{active, once}]),
	State2 = State#state{data_buffer = Buffer},
	{next_state, passive, State2};

passive({decoded_frames, Frames, Buffer}, #state{passive_from = undefined} = State) ->
	NewFrameBuffer = State#state.frame_buffer ++ Frames,
	if
		length(NewFrameBuffer) >= State#state.max_frame_buffer ->
			ok;
		true ->
			socket_setopts(State, [{active, once}])
	end,
	State2 = State#state{frame_buffer = NewFrameBuffer, data_buffer = Buffer},
	{next_state, passive, State2};

passive({decoded_frames, [Frame | Frames], Buffer}, #state{frame_buffer = []} = State) ->
	gen_fsm:reply(State#state.passive_from, {ok, Frame}),
	case State#state.passive_tref of
		undefined ->
			ok;
		_ ->
			gen_fsm:cancel_timer(State#state.passive_tref)
	end,
	if
		length(Frames) >= State#state.max_frame_buffer ->
			ok;
		true ->
			socket_setopts(State, [{active, once}])
	end,
	State2 = State#state{frame_buffer = Frames, data_buffer = Buffer, passive_from = undefined, passive_tref = undefined},
	{next_state, passive, State2};

passive(_Msg, State) ->
	{next_state, passive, State}.

%% @private
closed(close, _From, State) ->
	{reply, ok, closed, State};

closed({shutdown, Reason}, _From, State) ->
	{stop, Reason, ok, State};

closed(_Msg, _From, State) ->
	{reply, {error, closed}, closed, State}.

%% @private
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
	Acc;
mask_payload(Key, Bits, Acc) when bit_size(Bits) < 32 ->
	SizeToMask = bit_size(Bits),
	KeyMaskLeft = 32 - SizeToMask,
	<<SubKey:SizeToMask, _:KeyMaskLeft>> = <<Key:32>>,
	<<B:SizeToMask>> = Bits,
	B2 = B bxor SubKey,
	<<Acc/binary, B2:SizeToMask>>;
mask_payload(Key, <<B:32, Rest/binary>>, Acc) ->
	B2 = B bxor Key,
	Acc2 = <<Acc/binary, B2:32>>,
	mask_payload(Key, Rest, Acc2).


payload_length(N) when N =< 125 ->
	<<N:7>>;
payload_length(N) when N =< 65535 ->
	<<126:7, N:16>>;
payload_length(N) when N =< 16#7fffffffffffffff ->
	<<127:7, N:64>>.

build_opts(Opts) ->
	Fun = fun
		({active, true}, Rec) ->
			Rec#init_opts{mode = active};
		({active, false}, Rec) ->
			Rec#init_opts{mode = passive};
		({active, once}, Rec) ->
			Rec#init_opts{mode = active_once};
		({owner_exit, DoWhat}, Rec) ->
			Rec#init_opts{on_owner_exit = DoWhat}
	end,
	lists:foldl(Fun, #init_opts{}, Opts).

verify_opts([]) ->
	true;
verify_opts([{owner_exit, DoWhat} | Tail]) ->
	case DoWhat of
		close ->
			verify_opts(Tail);
		shutdown ->
			verify_opts(Tail);
		{shutdown, _} ->
			verify_opts(Tail);
		nothing ->
			verify_opts(Tail);
		_ ->
			false
	end;
verify_opts([{active, Activeness} | Tail]) ->
	if
		Activeness ->
			verify_opts(Tail);
		not Activeness ->
			verify_opts(Tail);
		Activeness =:= once ->
			verify_opts(Tail);
		true ->
			false
	end;
verify_opts(_) ->
	false.

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
			{active_once, State};
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
