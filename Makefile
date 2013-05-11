REPO        ?= rpg_battlemap

.PHONY: rel deps

all: deps compile

compile:
	./rebar compile

deps:
	./rebar get-deps

clean: testclean
	./rebar clean


TEST_LOG_FILE := eunit.log
testclean:
	@rm -f $(TEST_LOG_FILE)

eunit: clean deps compile
	./rebar eunit skip_deps=true

test: deps compile testclean
	./rebar eunit skip_deps=true

