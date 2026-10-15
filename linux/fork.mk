# UsageBar fork-only make targets (fork-owned).
# Upstream's root Makefile pulls this in with its single `-include linux/fork.mk`
# hook line. Add fork targets here instead of editing the root Makefile.

.PHONY: test-linux-ui

# Nested-GNOME dashboard smoke test (see linux/usagebar-gnome/README.md).
test-linux-ui:
	./linux/test-devkit-ui.sh
