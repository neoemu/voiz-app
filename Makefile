.PHONY: distribution-check distribution
distribution-check:
	./scripts/distribute.sh --check

distribution:
	./scripts/distribute.sh

# Local development: isolated app, stable build cache, no public release.
.PHONY: dev dev-build dev-open dev-status dev-stop test dev-script-test
export TEST_ONLY

dev:
	python3 scripts/dev.py run

dev-build:
	python3 scripts/dev.py build

dev-open:
	python3 scripts/dev.py open

dev-status:
	python3 scripts/dev.py status

dev-stop:
	python3 scripts/dev.py stop

test:
	python3 scripts/dev.py test

dev-script-test:
	python3 -m unittest discover -s scripts/tests -p test_dev_workflow.py
	uv run --with cryptography==50.0.1 python -m unittest discover -s scripts/tests -p test_sparkle_distribution.py
