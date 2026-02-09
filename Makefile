SHELL := /bin/bash
layer ?= *
resolve_php_versions = $(or $(php_versions),`jq -r '.php | join(" ")' ${1}/config.json`)
resolve_tags = `./new-docker-tags.php $(DOCKER_TAG)`
BREF_VERSION = 2

# BREF_BUILD_IMAGE must be passed (amd64: bref/build-php-XX:2, arm64: your/bref-build-php-84:2)
define build_docker_image
	docker build -t bref/${1}-php-${2} \
		--build-arg PHP_VERSION=${2} \
		--build-arg BREF_VERSION=${BREF_VERSION} \
		--build-arg BREF_BUILD_IMAGE=bref/build-php-${2}:${BREF_VERSION} \
		${DOCKER_BUILD_FLAGS} ${1}
endef

# ARM64: lightweight Dockerfile.arm64 (official php image). Only gd + excimer, PHP 84.
ARM64_PHP_VERSIONS = 84
define build_docker_image_arm
	$(eval PHP_TAG := $(shell echo ${2} | sed 's/^\(.\)\(.\)$$/\1.\2/'))
	docker build -f ${1}/Dockerfile.arm64 -t bref/${1}-php-${2} \
		--build-arg PHP_TAG=$(PHP_TAG) \
		--platform linux/arm64 \
		${DOCKER_BUILD_FLAGS} ${1}
endef

docker-images:
	if [ "${layer}" != "*" ]; then test -d layers/${layer}; fi
	set -e; \
	for dir in layers/${layer}; do \
		for php_version in $(call resolve_php_versions,$${dir}); do \
			echo "###############################################"; \
			echo "###############################################"; \
			echo "### Building $${dir} PHP$${php_version}"; \
			echo "###"; \
			$(call build_docker_image,$${dir},$${php_version}) ; \
			echo ""; \
		done \
	done

# Build ARM64 images (gd, excimer) via Dockerfile.arm64 – no extra base image needed.
docker-images-arm:
	if [ "${layer}" != "*" ]; then test -d layers/${layer}; fi
	set -e; \
	for dir in layers/${layer}; do \
		[ -f "$${dir}/Dockerfile.arm64" ] || { echo "### Skipping $${dir} (no Dockerfile.arm64)"; continue; }; \
		for php_version in $(ARM64_PHP_VERSIONS); do \
			echo "### Building ARM64 $${dir} PHP$${php_version}"; \
			$(call build_docker_image_arm,$${dir},$${php_version}); \
			echo ""; \
		done \
	done

# Build both gd and excimer for ARM in one go
docker-images-arm-gd-excimer:
	$(MAKE) docker-images-arm layer=gd
	$(MAKE) docker-images-arm layer=excimer

test: docker-images
	if [ "${layer}" != "*" ]; then test -d layers/${layer}; fi
	set -e; \
	for dir in layers/${layer}; do \
		for php_version in $(call resolve_php_versions,$${dir}); do \
			echo "###############################################"; \
			echo "###############################################"; \
			echo "### Testing $${dir} PHP$${php_version}"; \
			echo "###"; \
			docker build --build-arg PHP_VERSION=$${php_version} --build-arg TARGET_IMAGE=$${dir}-php-$${php_version} -t bref/test-$${dir}-$${php_version} tests ; \
			docker run --entrypoint= --rm -v $$(pwd)/$${dir}:/var/task bref/test-$${dir}-$${php_version} /opt/bin/php /var/task/test.php ; \
			if docker run --entrypoint= --rm -v $$(pwd)/$${dir}:/var/task bref/test-$${dir}-$${php_version} /opt/bin/php -v 2>&1 >/dev/null | grep -q 'Unable\|Warning'; then exit 1; fi ; \
			echo ""; \
			echo " - Test passed"; \
			echo ""; \
		done \
	done;

# The PHP runtimes
layers: docker-images
	if [ "${layer}" != "*" ]; then test -d layers/${layer}; fi
	PWD=pwd
	rm -rf export/layer-${layer}.zip || true
	mkdir -p export/tmp
	set -e; \
	for dir in layers/${layer}; do \
		for php_version in $(call resolve_php_versions,${PWD}/$${dir}); do \
			echo "###############################################"; \
			echo "###############################################"; \
			echo "### Exporting $${dir} PHP$${php_version}"; \
			echo "###"; \
			cd ${PWD} ; rm -rf export/tmp/${layer} || true ; cd export/tmp ; \
			CID=$$(docker create --entrypoint=scratch bref/$${dir}-php-$${php_version}) ; \
			docker cp $${CID}:/opt . ; \
			docker rm $${CID} ; \
			cd ./opt ; \
			zip --quiet -X --recurse-paths ../../`echo "$${dir}-php-$${php_version}" | sed -e "s/layers\//layer-/g"`.zip . ; \
			echo ""; \
		done \
	done
	rm -rf export/tmp

clean:
	rm -f export/layer-*

publish: layers
	php ./bref-extra publish
	php ./bref-extra list

# Publish docker images
publish-docker-images: docker-images
	for dir in layers/${layer}; do \
		for php_version in $(call resolve_php_versions,$${dir}); do \
			echo "###############################################"; \
			echo "###############################################"; \
			echo "### Publishing $${dir} PHP$${php_version}"; \
			echo "###"; \
			privateImage="bref/$${dir}-php-$${php_version}"; \
			publicImage=$${privateImage/layers\//extra-}; \
			echo "Image name: $$publicImage"; \
			echo ""; \
			echo "docker push $$publicImage:latest"; \
			docker tag $$privateImage:latest $$publicImage:latest; \
			docker push $$publicImage:latest; \
			if (test $(DOCKER_TAG)); then \
			  echo "Pushing tagged images"; \
			  for tag in $(call resolve_tags); do \
			    echo ""; \
			    echo "docker push $$publicImage:$${tag}"; \
			    docker tag $$privateImage:latest $$publicImage:$${tag}; \
			    docker push $$publicImage:$${tag}; \
			  done; \
			fi; \
			echo ""; \
		done \
	done

# Publish ARM64-only images (optional; for multi-arch use publish-docker-images-multi-arch)
publish-docker-images-arm: docker-images-arm
	@if [ -z "$(DOCKER_IMAGE_PREFIX)" ]; then echo "Set DOCKER_IMAGE_PREFIX (e.g. your Docker Hub username)"; exit 1; fi
	export DOCKER_IMAGE_PREFIX="$(DOCKER_IMAGE_PREFIX)" DOCKER_TAG="$(DOCKER_TAG)"; \
	for dir in layers/${layer}; do \
		case "$$(basename $${dir})" in gd|excimer) ;; *) continue;; esac; \
		for php_version in $(ARM64_PHP_VERSIONS); do \
			layer_name=$$(basename $${dir}); \
			privateImage="bref/$${dir}-php-$${php_version}"; \
			publicImage="$${DOCKER_IMAGE_PREFIX}/extra-$${layer_name}-php-$${php_version}"; \
			echo "### Publishing ARM64 $$publicImage"; \
			docker tag $$privateImage:latest $$publicImage:latest; \
			docker push $$publicImage:latest; \
			if (test -n "$$DOCKER_TAG"); then \
			  for tag in $(call resolve_tags); do \
			    docker tag $$privateImage:latest $$publicImage:$${tag}; \
			    docker push $$publicImage:$${tag}; \
			  done; \
			fi; \
		done \
	done

# Multi-arch (amd64 + arm64) on one tag. One run, ~5 min. No pre-built base image needed.
#   make publish-docker-images-multi-arch DOCKER_IMAGE_PREFIX=myuser DOCKER_TAG=1.8.6
publish-docker-images-multi-arch:
	@if [ -z "$(DOCKER_IMAGE_PREFIX)" ] || [ -z "$(DOCKER_TAG)" ]; then \
		echo "Usage: make publish-docker-images-multi-arch DOCKER_IMAGE_PREFIX=myuser DOCKER_TAG=1.8.6"; exit 1; fi
	$(MAKE) docker-images layer=gd php_versions=84
	$(MAKE) docker-images layer=excimer php_versions=84
	@for name in gd excimer; do \
		img="$(DOCKER_IMAGE_PREFIX)/extra-$$name-php-84"; \
		docker tag bref/layers/$$name-php-84:latest $$img:$(DOCKER_TAG)-amd64; \
		docker push $$img:$(DOCKER_TAG)-amd64; \
	done
	$(MAKE) docker-images-arm layer=gd
	$(MAKE) docker-images-arm layer=excimer
	@for name in gd excimer; do \
		img="$(DOCKER_IMAGE_PREFIX)/extra-$$name-php-84"; \
		docker tag bref/layers/$$name-php-84:latest $$img:$(DOCKER_TAG)-arm64; \
		docker push $$img:$(DOCKER_TAG)-arm64; \
	done
	@for name in gd excimer; do \
		img="$(DOCKER_IMAGE_PREFIX)/extra-$$name-php-84"; \
		echo "### Creating multi-arch manifest $$img:$(DOCKER_TAG)"; \
		docker buildx imagetools create -t $$img:$(DOCKER_TAG) $$img:$(DOCKER_TAG)-amd64 $$img:$(DOCKER_TAG)-arm64; \
	done

