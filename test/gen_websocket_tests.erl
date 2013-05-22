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
	{setup, local, fun() ->
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

		{"passive mode tests", setup, local, fun() ->
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
			end}

		] end},

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

		] end}

	] end}.