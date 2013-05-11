-module(gen_websocket_tests).

-include_lib("eunit/include/eunit.hrl").

connectivity_test_() ->
	{setup, fun() ->
		ws_server:start_link(<<"/ws">>, 9076)
	end,
	fun(Cowboy) ->
		ok
	end,
	fun(Cowboy) -> [

		{"connection success", fun() ->
			Got = gen_websocket:connect("ws://localhost:9076/ws", []),
			?assertMatch({ok, _Socket}, Got),
			gen_websocket:close(Got)
		end}

	] end}.
