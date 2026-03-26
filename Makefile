DOCKER_IMAGE := amneziawg-builder
WIREGUARD_VANILLA_IMAGE := wireguard-vanilla-builder
ROUTER_HOST  := root@192.168.1.1
OUTPUT_DIR   := output
WIREGUARD_REF ?=

.PHONY: all build build-wireguard-vanilla compare-wireguard compare-amnezia analyze-wireguard analyze-amnezia deploy verify clean

all: build

build:
	docker build -t $(DOCKER_IMAGE) .
	mkdir -p $(OUTPUT_DIR)
	docker run --rm \
		-v $(CURDIR)/kernel.config:/build/kernel.config:ro \
		-v $(CURDIR)/build.sh:/build/build.sh:ro \
		-v $(CURDIR)/output:/build/output \
		$(DOCKER_IMAGE) bash /build/build.sh

build-wireguard-vanilla:
	docker build -f Dockerfile.wireguard-vanilla -t $(WIREGUARD_VANILLA_IMAGE) .
	mkdir -p $(OUTPUT_DIR)
	docker run --rm \
		-e WIREGUARD_REF="$(WIREGUARD_REF)" \
		-v $(CURDIR)/kernel.config:/build/kernel.config:ro \
		-v $(CURDIR)/build-wireguard-vanilla.sh:/build/build-wireguard-vanilla.sh:ro \
		-v $(CURDIR)/output:/build/output \
		$(WIREGUARD_VANILLA_IMAGE) bash /build/build-wireguard-vanilla.sh

compare-wireguard:
	./compare-wireguard.sh $(CURDIR)/wireguard-device.ko $(CURDIR)/output/wireguard-vanilla.ko $(CURDIR)/output/wireguard-compare

compare-amnezia:
	MODULE_A_LABEL=amnezia MODULE_B_LABEL=vanilla ./compare-wireguard.sh $(CURDIR)/output/amneziawg.ko $(CURDIR)/output/wireguard-vanilla.ko $(CURDIR)/output/amnezia-compare

analyze-wireguard: build-wireguard-vanilla compare-wireguard

analyze-amnezia: build-wireguard-vanilla compare-amnezia

deploy:
	./deploy.sh $(ROUTER_HOST)

verify:
	ssh $(ROUTER_HOST) "lsmod | grep amneziawg"
	ssh $(ROUTER_HOST) "/data/amneziawg/awg --version"
	ssh $(ROUTER_HOST) "ip link add awg-test type amneziawg && ip link del awg-test && echo 'Interface test OK'"

clean:
	rm -rf $(OUTPUT_DIR)/*
