REBAR3_BIN := $(shell which rebar3 2>/dev/null)
ifeq (, ${REBAR3_BIN})
REBAR3_BIN = ./rebar3
endif

all: rebar3 compile

compile:
	@echo Using ${REBAR3_BIN}
	@${REBAR3_BIN} compile

clean:
	@${REBAR3_BIN} clean

distclean: clean 
	@${REBAR3_BIN} unlock ;\
	rm -Rf _build ;\
	rm -Rf rebar3

rebar3:
ifeq (./rebar3, ${REBAR3_BIN})
	@echo 'rebar3 not found in $$PATH'
	@echo "==> install rebar3"
	curl -L -O --progress-bar https://s3.amazonaws.com/rebar3/rebar3
	@chmod +x $@
endif
