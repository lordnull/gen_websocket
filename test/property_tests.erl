-module(property_tests).

-ifdef(PROPER).
-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-compile(export_all).

-record(conn, {socket, queue = []}).

setup() ->
	ws_server:start_link(<<"/pws">>, 9077).

teardown() ->
	ws_server:stop().

many_connections_test_() ->
	{timeout, 10000, fun() ->
		{ok, Server} = setup(),
		?assert(proper:quickcheck(proper:numtests(50, ?MODULE:prop_statem()), [{to_file, user}])),
		unlink(Server),
		teardown()
	end}.

until_error() ->
	{ok, Server} = setup(),
	Out = connect_until_error(),
	unlink(Server),
	teardown(),
	Out.

connect_until_error() ->
	connect_until_error([]).

connect_until_error(Acc) ->
	case gen_websocket:connect("ws://localhost:9077/pws", []) of
		{ok, Socket} ->
			connect_until_error([Socket | Acc]);
		Else ->
			[gen_websocket:shutdown(S, normal) || S <- Acc],
			{length(Acc), Else}
	end.

prop_statem() ->
	?FORALL(Cmds, commands(?MODULE), begin
		{Hist, State, Res} = run_commands(?MODULE, Cmds),
		aggregate(command_names(Cmds), ?WHENFAIL(
			?debugFmt("~n=== Proper Check Failed ===~n"
				"  == History ==~n"
				"~p~n~n"
				" == State ==~n"
				"~p~n~n"
				" == Result ==~n"
				"~p~n", [Hist, State, Res]),
			Res == ok))
	end).

initial_state() ->
	[].

command([]) ->
	{call, ?MODULE, new_connection, []};
command(Queues) when length(Queues) >= 10 ->
	frequency([
		{10, {call, ?MODULE, send, [g_type(), binary()]}},
		{length(Queues) * 8, {call, ?MODULE, recv, [elements(Queues)]}},
		{1, {call, ?MODULE, disconnect, [elements(Queues)]}}
	]);
command(Queues) ->
	frequency([
		{1, {call, ?MODULE, new_connection, []}},
		{10, {call, ?MODULE, send, [g_type(), binary()]}},
		{length(Queues) * 8, {call, ?MODULE, recv, [elements(Queues)]}},
		{1, {call, ?MODULE, disconnect, [elements(Queues)]}}
	]).

g_type() ->
	oneof([text, binary]).

get_socket({ok, S}) ->
	S.

next_state(S, R, {call, ?MODULE, new_connection, []}) ->
	lists:keystore(R, #conn.socket, S, #conn{socket = {call, ?MODULE, get_socket, [R]}});

next_state(S, _R, {call, ?MODULE, disconnect, [Ws]}) ->
	lists:keydelete(Ws#conn.socket, #conn.socket, S);

next_state(S, _R, {call, ?MODULE, recv, [Ws]}) ->
	case Ws#conn.queue of
		[] ->
			S;
		[_Msg | Tail] ->
			lists:keystore(Ws#conn.socket, #conn.socket, S, Ws#conn{queue = Tail})
	end;

next_state(S, _R, {call, ?MODULE, send, [Type, Binary]}) ->
	[Conn#conn{queue = Q ++ [{Type, Binary}]} || #conn{queue = Q} = Conn <- S].

precondition(_S, _Call) ->
	true.

postcondition(_S, {call, ?MODULE, new_connection, []}, R) ->
	ok == ?assertMatch({ok, _Socket}, R);

postcondition(_S, {call, ?MODULE, disconnect, [_Ws]}, R) ->
	ok == ?assertEqual(ok, R);

postcondition(_S, {call, ?MODULE, recv, [Ws]}, R) ->
	case Ws#conn.queue of
		[] ->
			ok == ?assertEqual({error, timeout}, R);
		[Expected | _] ->
			ok == ?assertEqual({ok, Expected}, R)
	end;

postcondition(_S, {call, ?MODULE, send, _}, _R) ->
	true.

new_connection() ->
	gen_websocket:connect("ws://localhost:9077/pws", [{owner_exit, {shutdown, normal}}]).

disconnect(#conn{socket = S}) ->
	gen_websocket:shutdown(S, normal).

recv(#conn{socket = S}) ->
	gen_websocket:recv(S, 1000).

send(Type, Binary) ->
	ws_server:send({Type, Binary}).

-endif.
