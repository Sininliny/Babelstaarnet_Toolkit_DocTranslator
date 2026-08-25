.PHONY: build build-mlx test check-privacy full-run app app-mlx run install clean

build:
	swift build

# With the app's own vision-language model. Needs Xcode for the Metal
# compiler; `make build` is the same app without it.
build-mlx:
	MLX=1 ./Scripts/build-with-mlx.sh build

# Everything: the logic, the layout, the agents end to end against fixtures,
# and Apple Vision reading a page of rendered Chinese. No models, no server,
# and no network — a fresh clone runs this.
test: check-privacy
	swift run Checks

# The whole app on a real page, with the real engines. Needs the weights and
# a few minutes; not part of `make test` for exactly that reason.
full-run:
	MLX=1 ./Scripts/build-with-mlx.sh run Checks --full-run ./dist/run

check-privacy:
	./Scripts/check-privacy.sh

app:
	./Scripts/build-app.sh

app-mlx:
	MLX=1 ./Scripts/build-app.sh

run: app
	open "./dist/Læsesalen.app"

install:
	./Scripts/install-app.sh

clean:
	swift package clean
	rm -rf ./dist
