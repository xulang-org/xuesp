XU ?= xu

.PHONY: build app run run-app check test clean

build:
	$(XU) build . -o xuesp

app:
	$(XU) build . --desktop -o xuesp

run: build
	./xuesp

run-app: app
	open xuesp.app

check:
	$(XU) check .

test:
	$(XU) test .

clean:
	rm -f xuesp
	rm -rf xuesp.app
