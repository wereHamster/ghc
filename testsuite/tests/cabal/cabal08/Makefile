TOP=../../..
include $(TOP)/mk/boilerplate.mk
include $(TOP)/mk/test.mk

SETUP=../Setup -v0

# in both cases, p2 should be preferred
cabal08: clean
	$(MAKE) clean
	'$(GHC_PKG)' init tmp1.d
	'$(GHC_PKG)' init tmp2.d
	'$(TEST_HC)' -v0 --make Setup
	cd p1 && $(SETUP) clean
	cd p1 && $(SETUP) configure $(CABAL_MINIMAL_BUILD) --with-ghc='$(TEST_HC)' --ghc-options='$(TEST_HC_OPTS)' --package-db=../tmp1.d --prefix='$(PWD)/inst-p1'
	cd p1 && $(SETUP) build
	cd p1 && $(SETUP) copy
	cd p1 && $(SETUP) register
	cd p2 && $(SETUP) clean
	cd p2 && $(SETUP) configure $(CABAL_MINIMAL_BUILD) --with-ghc='$(TEST_HC)' --ghc-options='$(TEST_HC_OPTS)' --package-db=../tmp2.d --prefix='$(PWD)/inst-p2'
	cd p2 && $(SETUP) build
	cd p2 && $(SETUP) copy
	cd p2 && $(SETUP) register
	'$(TEST_HC)' $(TEST_HC_OPTS) -package-db tmp1.d -package-db tmp2.d Main.hs
	./Main
	'$(TEST_HC)' $(TEST_HC_OPTS) -package-db tmp1.d -package-db tmp2.d -hide-all-packages -package base -package p Main.hs
	./Main
ifneq "$(CLEANUP)" ""
	$(MAKE) clean
endif

clean :
	$(RM) -r tmp*.d inst-* *.o *.hi */*.o */*.hi */Setup$(exeext) */dist Setup$(exeext)
