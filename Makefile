MAKEFILE_NAME := $(word $(words $(MAKEFILE_LIST)),$(MAKEFILE_LIST))
# Include custom config if it is available
-include Makefile.config
APP_ROOT    := $(abspath $(lastword $(MAKEFILE_NAME))/..)
APP_NAME    := stac-app
APP_VERSION ?= 2.4.0

DOCKER_TAG := ghcr.io/crim-ca/$(APP_NAME):$(APP_VERSION)
DOCKER_XARGS ?=
DOCKER_NETWORK ?= stac-network
DOCKER_DB_NAME ?= postgres
DOCKER_DB_IMAGE ?= ghcr.io/stac-utils/pgstac:v0.9.8
DOCKER_RUN_IMAGE ?= $(DOCKER_TAG)
DOCKER_TEST_IMAGE ?= curlimages/curl:8.21.0

docker-build:
	docker build "$(APP_ROOT)" -f "$(APP_ROOT)/Dockerfile" -t "$(DOCKER_TAG)" $(DOCKER_XARGS)

docker-network:
	docker network create $(DOCKER_NETWORK) || true

docker-pg: docker-network
	docker ps | grep $(DOCKER_DB_NAME) || \
	docker run --rm -d \
		--network $(DOCKER_NETWORK) \
		-e POSTGRES_PASSWORD=postgres \
		-e POSTGRES_USER=postgres \
		-e POSTGRES_DB=postgis \
		-e PGDATABASE=postgis \
		-e PGUSER=postgres \
		-e PGPASSWORD=postgres \
		--name $(DOCKER_DB_NAME) \
		$(DOCKER_DB_IMAGE)

docker-run: docker-network docker-pg
	docker run --rm -d \
		--network $(DOCKER_NETWORK) \
		-p 8000:8000 \
		-e POSTGRES_DBNAME=postgis \
		-e POSTGRES_PASSWORD=postgres \
		-e POSTGRES_USER=postgres \
		-e POSTGRES_DB=postgis \
		-e PGDATABASE=postgis \
		-e PGUSER=postgres \
		-e PGPASSWORD=postgres \
		-e PGHOST=$(DOCKER_DB_NAME) \
		-e POSTGRES_HOST_READER=$(DOCKER_DB_NAME) \
		-e POSTGRES_HOST_WRITER=$(DOCKER_DB_NAME) \
		-e POSTGRES_PORT=5432 \
		-e ROUTER_PREFIX=/stac \
		--name $(APP_NAME) \
		$(DOCKER_RUN_IMAGE)

docker-test: docker-network
	docker run --rm \
		--network $(DOCKER_NETWORK) \
		$(DOCKER_TEST_IMAGE) \
		curl \
			--retry 3 \
			--retry-delay 5 \
			--retry-max-time 30 \
			--retry-connrefused \
			"http://$(APP_NAME):8000/stac/" \
			| grep '"type":"Catalog","id":"stac-fastapi"'

docker-stop:
	docker stop $(DOCKER_DB_NAME) || true
	docker stop $(APP_NAME) || true

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
