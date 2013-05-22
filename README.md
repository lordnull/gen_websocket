# gen_websocket
[![Build Status](https://travis-ci.org/lordnull/gen_websocket.png)](https://travis-ci.org/lordnull/gen_websocket)

## Overview

Conceptually, a websocket is most like gen_tcp than gen_server. This
provides a gen_tcp-ish interface for interacting with websocket servers,
including active, active once, and passive modes.

## Features

Connect to websocket servers using websocket version 13. Able to send and
recieve messages.

## Compiling

    make

To run tests:

    make test

