
COMPILER=GNU

ifndef COMPILER
$(error No compiler specified!)
endif

SRC_DIR=./src

all:
	@$(MAKE) -C $(SRC_DIR) COMPILER=$(COMPILER)                NO_OMP=1 SUFFIX=_default
	@$(MAKE) -C $(SRC_DIR) COMPILER=$(COMPILER) FAST_MATH=1    NO_OMP=1 SUFFIX=_relaxed
	@$(MAKE) -C $(SRC_DIR) COMPILER=$(COMPILER) PRECISE_MATH=1 NO_OMP=1 SUFFIX=_precise

# Build a single test: make s1111, make COMPILER=clang s1111
%:
	@$(MAKE) -C $(SRC_DIR) COMPILER=$(COMPILER) TEST=$@

.PHONY: clean
clean:
	$(MAKE) -C $(SRC_DIR) COMPILER=$(COMPILER) clean

