-module(gen_websocket_tests).

-include_lib("eunit/include/eunit.hrl").

connectivity_test_() ->
	{setup, fun() ->
		{ok, Cowboy} = ws_server:start_link(<<"/ws">>, 9076),
		Cowboy
	end,
	fun(Cowboy) ->
		unlink(Cowboy),
		ws_server:stop()
	end,
	fun(Cowboy) -> [

		{"connect to non-existant endpoing", fun() ->
			Got = gen_websocket:connect("ws://localhost:9076/favicon.ico", []),
			?assertEqual({error, {404, <<"Not Found">>}}, Got)
		end},

		{"connection success", fun() ->
			Got = gen_websocket:connect("ws://localhost:9076/ws", []),
			?assertMatch({ok, _Socket}, Got),
			gen_websocket:close(element(2, Got))
		end},

		{"close a connection while in active true", fun() ->
			{ok, Ws} = gen_websocket:connect("ws://localhost:9076/ws", [{active, true}]),
			Got = gen_websocket:close(Ws),
			?assertEqual(ok, Got)
		end},

		{"close a connection while in active false", fun() ->
			{ok, Ws} = gen_websocket:connect("ws://localhost:9076/ws", [{active, false}]),
			Got = gen_websocket:close(Ws),
			?assertEqual(ok, Got)
		end},

		{"close a connection while in active once", fun() ->
			{ok, Ws} = gen_websocket:connect("ws://localhost:9076/ws", [{active, once}]),
			Got = gen_websocket:close(Ws),
			?assertEqual(ok, Got)
		end},

		{"connect with custom headers", fun() ->
			Headers = [{<<"goobers">>, <<"cool">>}, <<"pants: plaid">>],
			{ok, Ws} = gen_websocket:connect("ws://localhost:9076/ws", [{headers, Headers}]),
			[Handler] = ws_server:handlers(),
			GooberHead = ws_server:header(Handler, <<"goobers">>),
			PantsHead = ws_server:header(Handler, <<"pants">>),
			?assertEqual({ok, <<"cool">>}, GooberHead),
			?assertEqual({ok, <<"plaid">>}, PantsHead)
		end},

		{"closed socket tests", setup, local, fun() ->
			{ok, Ws} = gen_websocket:connect("ws://localhost:9076/ws", []),
			gen_websocket:close(Ws),
			Ws
		end,
		fun(Ws) ->
			catch gen_websocket:shutdown(Ws, normal)
		end,
		fun(Ws) -> [

			{"can't recv", fun() ->
				Got = gen_websocket:recv(Ws, 1000),
				?assertEqual({error, closed}, Got)
			end},

			{"can't setopts", fun() ->
				Got = gen_websocket:setopts(Ws, [{active, once}]),
				?assertEqual({error, closed}, Got)
			end},

			{"can't send", fun() ->
				Got = gen_websocket:send(Ws, <<"sending on a closed socket">>),
				?assertEqual({error, closed}, Got)
			end},

			{"can't change controller", fun() ->
				Pid = spawn(fun() ->
					receive _ -> ok end
				end),
				Got = gen_websocket:controlling_process(Ws, Pid),
				?assertEqual({error, closed}, Got),
				Pid ! done
			end},

			{"can't ping", fun() ->
				Got = gen_websocket:ping(Ws),
				?assertEqual({error, closed}, Got)
			end},

			{"can close", fun() ->
				Got = gen_websocket:close(Ws),
				?assertEqual(ok, Got)
			end},

			{"can shutdown", fun() ->
				Got = gen_websocket:shutdown(Ws, normal),
				?assertEqual(ok, Got)
			end}

		] end}

	] end}.


communication_test_() ->
	{timeout, 10000, {setup, local, fun() ->
		{ok, Cowboy} = ws_server:start_link(<<"/ws">>, 9077),
		{ok, WS} = gen_websocket:connect("ws://localhost:9077/ws", []),
		[Handler] = ws_server:handlers(),
		?debugFmt("the me: ~p", [self()]),
		{Cowboy, WS, Handler}
	end,
	fun({Cowboy, WS, _Handler}) ->
		gen_websocket:close(WS),
		unlink(Cowboy),
		ws_server:stop()
	end,
	fun({Cowboy, WS, Handler}) -> [

		{"send a frame", fun() ->
			Msg = <<"send a frame test">>,
			Got1 = gen_websocket:send(WS, Msg),
			?assertEqual(ok, Got1),
			timer:sleep(1000),
			Got2 = ws_server:reset_msgs(Handler),
			?assertEqual([Msg], Got2)
		end},

		{"can swap mode to active: once", fun() ->
			Got = gen_websocket:setopts(WS, [{active, once}]),
			?assertEqual(ok, Got)
		end},

		{"can swap mode to active: true", fun() ->
			Got = gen_websocket:setopts(WS, [{active, true}]),
			?assertEqual(ok, Got)
		end},

		{"can swap mode to passive (active: false)", fun() ->
			Got = gen_websocket:setopts(WS, [{active, false}]),
			?assertEqual(ok, Got)
		end},

		{"passive mode tests", timeout, 10000, {setup, local, fun() ->
			?debugFmt("My pid: ~p", [self()]),
			gen_websocket:setopts(WS, [{active, false}])
		end, fun(_) ->
			ok
		end,
		fun(_) -> [

			{"passive receive a frame", fun() ->
				?debugFmt("and pid report: ~p", [self()]),
				Msg = <<"I'm a little teapot">>,
				ws_server:send(Msg),
				Got = gen_websocket:recv(WS),
				?assertEqual({ok, {text, Msg}}, Got)
			end},

			{"recv while recv gets an error", fun() ->
				spawn(fun() -> gen_websocket:recv(WS) end),
				Self = self(),
				spawn(fun() ->
					Got = gen_websocket:recv(WS),
					Self ! {ok, Got}
				end),
				Got = receive
					{ok, Res} ->
						Res
				after 100 ->
					timeout
				end,
				ws_server:send(<<"you're going down">>),
				?assertEqual({error, already_recv}, Got)
			end},

			{"passive multiple recvs", fun() ->
				Msgs = [{ok, {text, M}} || M <- [<<"sending1">>, <<"sending2">> ,<<"sending3">>]],
				[ws_server:send(M) || {ok, M} <- Msgs],
				Got = [gen_websocket:recv(WS) || _ <- lists:seq(1,3)],
				?assertEqual(Msgs, Got)
			end},

			{"passive timeouts", fun() ->
				Got = gen_websocket:recv(WS, 1000),
				?assertEqual({error, timeout}, Got)
			end},

			{"no active message while passive", fun() ->
				Msg = <<"this is beckmen">>,
				ws_server:send(Msg),
				Got = receive
					{gen_websocket, WS, SocketData} ->
						{error, SocketData}
				after 1000 ->
					timeout
				end,
				?assertEqual(timeout, Got),
				AlsoGot = gen_websocket:recv(WS),
				?assertEqual({ok, {text, Msg}}, AlsoGot)
			end},

			{"timeout longer than gen_fsm default of 5 seconds", timeout, 10000, fun() ->
				Got = gen_websocket:recv(WS, 6000),
				?assertEqual({error, timeout}, Got)
			end}

		] end}},

		{"active once mode tests", setup, local, fun() ->
			gen_websocket:setopts(WS, [{active, once}])
		end,
		fun(_) ->
			ok
		end,
		fun(_) -> [

			{"cannot do passive recv", fun() ->
				Got = gen_websocket:recv(WS, 1000),
				?assertEqual({error, not_passive}, Got)
			end},

			{"gets a message", fun() ->
				?debugFmt("the me: ~p", [self()]),
				Msg = <<"justice league, assemble!">>,
				ws_server:send(Msg),
				Got = receive
					{gen_websocket, WS, {text, Msg}} ->
						ok
				after 1000 ->
					timeout
				end,
				?assertEqual(ok, Got)
			end},

			{"transitioned to passive mode", fun() ->
				Got = gen_websocket:recv(WS, 1000),
				?assertEqual({error, timeout}, Got)
			end},

			{"receive a bunch", fun() ->
				Msgs = [{text, M} || M <- [<<"der thing 1">>, <<"der thing 2">>, <<"der thing 3">>]],
				[ws_server:send(M) || M <- Msgs],
				FoldFun = fun(_, Acc) ->
					gen_websocket:setopts(WS, [{active, once}]),
					receive
						{gen_websocket, WS, Msg} ->
							Acc ++ [Msg]
					after 1000 ->
						Acc ++ [{error, timeout}]
					end
				end,
				Got = lists:foldl(FoldFun, [], Msgs),
				?assertEqual(Msgs, Got)
			end}

		] end},

		{"active mode tests", setup, local, fun() ->
			gen_websocket:setopts(WS, [{active, true}])
		end,
		fun(_) ->
			ok
		end,
		fun(_) -> [

			{"can't do recv", fun() ->
				Got = gen_websocket:recv(WS),
				?assertEqual({error, not_passive}, Got)
			end},

			{"gets a bunch of messages", fun() ->
				Msgs = [{text, M} || M <- [<<"vonder 1">>, <<"vonder 2">>, <<"vonder 3">>]],
				[ws_server:send(M) || M <- Msgs],
				FoldFun = fun(_, Acc) ->
					receive
						{gen_websocket, WS, M} ->
							Acc ++ [M]
					after 1000 ->
						Acc ++ [{error, timeout}]
					end
				end,
				Got = lists:foldl(FoldFun, [], Msgs),
				?assertEqual(Msgs, Got)
			end}

		] end},

		{"ping pong handling tests", setup, local, fun() ->
			ws_server:reset_msgs(Handler),
			gen_websocket:setopts(WS, [{active, false}])
		end,
		fun(_) ->
			ok
		end,
		fun(_) -> [

			{"can do blocking ping", fun() ->
				Res = gen_websocket:ping(WS),
				?assertEqual(pong, Res)
			end},

			{"pings can timeout", fun() ->
				% cowboy always replies to pings, so we suspend the process
				% to force a timeout.
				erlang:suspend_process(Handler, [unless_suspending]),
				Res = gen_websocket:ping(WS, 1),
				erlang:resume_process(Handler),
				?assertEqual(pang, Res)
			end},

			{"auto reply to pings", fun() ->
				gen_websocket:setopts(WS, [{ping, pong}]),
				ws_server:send(Handler, ping, <<>>),
				% give the cowboy server time to do stuff
				timer:sleep(1000),
				MaybePong = ws_server:reset_msgs(Handler),
				?assertMatch([pong | _], MaybePong)
			end},

			{"delivery of pings", fun() ->
				gen_websocket:setopts(WS, [{ping, deliver}]),
				ws_server:send(Handler, ping, <<>>),
				timer:sleep(1000),
				Got = gen_websocket:recv(WS, 1000),
				?assertEqual({ok, {ping, <<>>}}, Got)
			end},

			{"queued up pings replied to when switching from deliver to pong", fun() ->
				gen_websocket:setopts(WS, [{ping, deliver}]),
				ws_server:reset_msgs(Handler),
				[ws_server:send(Handler, ping, <<>>) || _ <- lists:seq(1, 3)],
				gen_websocket:setopts(WS, [{ping, pong}]),
				timer:sleep(1000),
				Msgs = ws_server:reset_msgs(Handler),
				?assertEqual([pong, pong, pong], Msgs)
			end}

		] end}

	] end}}.

options_test_() ->
	{setup, local, fun() ->
		{ok, Cowboy} = ws_server:start_link(<<"/ws">>, 9078),
		Url = "ws://localhost:9078/ws",
		{Cowboy, Url}
	end,
	fun({Cowboy, _Url}) ->
		unlink(Cowboy),
		ws_server:stop()
	end,
	fun({Cowboy, Url}) -> [

		{"give control away", fun() ->
			{ok, Ws} = gen_websocket:connect(Url, [{active, once}]),
			Self = self(),
			Pid = spawn(fun() ->
				receive
					{gen_websocket, Ws, Frame} ->
						Self ! {got_frame, Frame}
				end
			end),
			Got1 = gen_websocket:controlling_process(Ws, Pid),
			Msg = <<"control given">>,
			ws_server:send(Msg),
			Got2 = receive
				{got_frame, Frame} ->
					Frame
			after 1000 ->
				{error, timeout}
			end,
			Got3 = receive
				{gen_websocket, Ws, {text, Msg}} ->
					{error, got_frame}
			after 1000 ->
				true
			end,
			exit(Pid, normal),
			gen_websocket:shutdown(Ws, normal),
			?assertEqual(ok, Got1),
			?assertEqual({text, Msg}, Got2),
			?assert(Got3)
		end},

		{"close on owner exit", fun() ->
			Self = self(),
			spawn(fun() ->
				{ok, Ws} = gen_websocket:connect(Url, [{owner_exit, close}]),
				Self ! {socket, Ws}
			end),
			Ws = receive
				{socket, InS} ->
					InS
			end,
			Got = gen_websocket:recv(Ws, 1000),
			?assertEqual({error, closed}, Got),
			gen_websocket:shutdown(Ws, normal)
		end},

		{"shutdwon on owner exit", fun() ->
			Self = self(),
			spawn(fun() ->
				{ok, Ws} = gen_websocket:connect(Url, [{owner_exit, shutdown}]),
				Self ! {socket, Ws}
			end),
			S = receive
				{socket, Ws} ->
					Ws
			end,
			?assertExit(_, gen_websocket:recv(S, 1000)),
			?assertExit({noproc, _}, gen_websocket:recv(S, 1000))
		end},

		{"shutdown with a reason on owner exit", fun() ->
			Self = self(),
			spawn(fun() ->
				{ok, Ws} = gen_websocket:connect(Url, [{owner_exit, {shutdown, fail}}]),
				Self ! {socket, ws}
			end),
			Ws = receive
				{socket, S} -> S
			end,
			?assertExit({noproc, _}, gen_websocket:recv(Ws, 1000))
		end},

		{"do nothing on owner exit", fun() ->
			Self = self(),
			spawn(fun() ->
				{ok, Ws} = gen_websocket:connect(Url, [{owner_exit, nothing}]),
				Self ! {socket, Ws}
			end),
			Ws = receive
				{socket, S} -> S
			end,
			?assertEqual({error, timeout}, gen_websocket:recv(Ws, 100))
		end}

	] end}.
