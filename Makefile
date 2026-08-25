.PHONY: build test check-privacy app run install clean

build:
	swift build

# Everything: the logic, the layout, the agents end to end against fixtures,
# and Apple Vision reading a page of rendered Chinese. No models, no server,
# and no network — a fresh clone runs this.
test: check-privacy
	swift run Checks

check-privacy:
	./Scripts/check-privacy.sh

app:
	./Scripts/build-app.sh

run: app
	open "./dist/Læsesalen.app"

install:
	./Scripts/install-app.sh

clean:
	swift package clean
	rm -rf ./dist
