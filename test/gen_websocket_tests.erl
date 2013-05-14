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
			gen_websocket:close(Got)
		end}

	] end}.


communication_test_() ->
	{setup, fun() ->
		{ok, Cowboy} = ws_server:start_link(<<"/ws">>, 9077),
		{ok, WS} = gen_websocket:connect("ws://localhost:9077/ws", []),
		[Handler] = ws_server:handlers(),
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
		end}

	] end}.