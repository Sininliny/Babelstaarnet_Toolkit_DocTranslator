.PHONY: build build-mlx test check-privacy full-run app app-mlx app-lean \
	run install clean

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

# The app bundle, with its own vision model in it wherever this Mac can
# compile one. The Metal compiler comes with Xcode rather than with the
# Command Line Tools, so on a machine without it this builds the app that has
# Apple's engines and nothing of its own — and says so, as does the Models
# screen inside it.
app:
	./Scripts/build-app.sh

# The same, insisting: fail rather than quietly hand back the smaller app.
# Worth having in CI and in a release, where the difference between the two
# bundles is not something to discover from a user.
app-mlx:
	MLX=1 ./Scripts/build-app.sh

# Deliberately without the engine. Builds in a fraction of the time, which is
# the only reason to want it.
app-lean:
	MLX=0 ./Scripts/build-app.sh

run: app
	open "./dist/Laesesalen.app"

install:
	./Scripts/install-app.sh

clean:
	swift package clean
	rm -rf ./dist
