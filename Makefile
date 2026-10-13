.PHONY: check lint test

check: lint test

lint:
	shellcheck -s bash bin/headrun engines/*.sh tests/*.sh install.sh

test:
	./tests/run.sh
