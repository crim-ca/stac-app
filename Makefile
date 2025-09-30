MAKEFILE_NAME := $(word $(words $(MAKEFILE_LIST)),$(MAKEFILE_LIST))
# Include custom config if it is available
-include Makefile.config
APP_ROOT    := $(abspath $(lastword $(MAKEFILE_NAME))/..)
APP_NAME    := stac-app
APP_VERSION ?= 2.0.2

DOCKER_TAG := ghcr.io/crim-ca/stac-app:$(APP_VERSION)
DOCKER_XARGS ?=

docker-build:
	docker build "$(APP_ROOT)" -f "$(APP_ROOT)/Dockerfile" -t "$(DOCKER_TAG)" $(DOCKER_XARGS)

install:
	pip install "$(APP_ROOT)"

install-dev:
	pip install "$(APP_ROOT)[dev]"

format:
	pre-commit run --all-files

clean:
	@rm -fr "$(APP_ROOT)/build/"
	@rm -fr "$(APP_ROOT)/**/*.egg-info"
	@rm -fr "$(APP_ROOT)/**/__pycache__"

## -- Versioning targets -------------------------------------------------------------------------------------------- ##

# Bumpversion 'dry' config
# if 'dry' is specified as target, any bumpversion call using 'BUMP_XARGS' will not apply changes
BUMP_TOOL := bump-my-version
BUMP_XARGS ?= --verbose --allow-dirty
ifeq ($(filter dry, $(MAKECMDGOALS)), dry)
	BUMP_XARGS := $(BUMP_XARGS) --dry-run
endif
.PHONY: dry
dry: pyproject.toml		## run 'bump' target without applying changes (dry-run) [make VERSION=<x.y.z> bump dry]
	@-echo > /dev/null

.PHONY: bump
bump:  ## bump version using VERSION specified as user input [make VERSION=<x.y.z> bump]
	@-echo "Updating package version ..."
	@[ "${VERSION}" ] || ( echo ">> 'VERSION' is not set"; exit 1 )
	@-bash -c '$(CONDA_CMD) $(BUMP_TOOL) bump $(BUMP_XARGS) --new-version "${VERSION}" patch;'

.PHONY: version
version:	## display current version
	@-echo "$(APP_NAME) version: $(APP_VERSION)"
