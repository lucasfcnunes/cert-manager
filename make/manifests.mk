HELM_CMD=./$(BINDIR)/tools/helm

ALLCRDS=deploy/crds/crd-certificaterequests.yaml deploy/crds/crd-certificates.yaml deploy/crds/crd-challenges.yaml deploy/crds/crd-clusterissuers.yaml deploy/crds/crd-issuers.yaml deploy/crds/crd-orders.yaml

HELM_TEMPLATE_SOURCES=$(wildcard deploy/charts/cert-manager/templates/*.yaml)
HELM_TEMPLATE_TARGETS=$(patsubst deploy/charts/cert-manager/templates/%,$(BINDIR)/helm/cert-manager/templates/%,$(HELM_TEMPLATE_SOURCES))

####################
# Friendly Targets #
####################

# These targets provide friendly names for the various manifests / charts we build

.PHONY: helm-chart
helm-chart: $(BINDIR)/cert-manager-$(RELEASE_VERSION).tgz

$(BINDIR)/cert-manager.tgz: $(BINDIR)/cert-manager-$(RELEASE_VERSION).tgz
	@ln -s -f $(notdir $<) $@

.PHONY: helm-chart-signature
helm-chart-signature: $(BINDIR)/cert-manager-$(RELEASE_VERSION).tgz.prov

.PHONY: static-manifests
static-manifests: $(BINDIR)/yaml/cert-manager.crds.yaml $(BINDIR)/yaml/cert-manager.yaml

###################
# Release Targets #
###################

.PHONY: release-manifests
## Build YAML manifests and helm charts (but not the helm chart signature)
##
## @category Release
release-manifests: $(BINDIR)/scratch/cert-manager-manifests-unsigned.tar.gz

.PHONY: release-manifests-signed
## Build YAML manifests and helm charts including the helm chart signature
##
## Since this command signs artifacts, this requires CMREL_KEY to be configured.
## Prefer `make release-manifests` locally.
##
## @category Release
release-manifests-signed: $(BINDIR)/release/cert-manager-manifests.tar.gz $(BINDIR)/metadata/cert-manager-manifests.tar.gz.metadata.json

$(BINDIR)/release/cert-manager-manifests.tar.gz: $(BINDIR)/cert-manager-$(RELEASE_VERSION).tgz $(BINDIR)/yaml/cert-manager.crds.yaml $(BINDIR)/yaml/cert-manager.yaml $(BINDIR)/cert-manager-$(RELEASE_VERSION).tgz.prov | $(BINDIR)/scratch/manifests-signed $(BINDIR)/release
	mkdir -p $(BINDIR)/scratch/manifests-signed/deploy/chart/
	mkdir -p $(BINDIR)/scratch/manifests-signed/deploy/manifests/
	cp $(BINDIR)/cert-manager-$(RELEASE_VERSION).tgz $(BINDIR)/cert-manager-$(RELEASE_VERSION).tgz.prov $(BINDIR)/scratch/manifests-signed/deploy/chart/
	cp $(BINDIR)/yaml/cert-manager.crds.yaml $(BINDIR)/yaml/cert-manager.yaml $(BINDIR)/scratch/manifests-signed/deploy/manifests/
	# removes leading ./ from archived paths
	find $(BINDIR)/scratch/manifests-signed -maxdepth 1 -mindepth 1 | sed 's|.*/||' | tar czf $@ -C $(BINDIR)/scratch/manifests-signed -T -
	rm -rf $(BINDIR)/scratch/manifests-signed

$(BINDIR)/scratch/cert-manager-manifests-unsigned.tar.gz: $(BINDIR)/cert-manager-$(RELEASE_VERSION).tgz $(BINDIR)/yaml/cert-manager.crds.yaml $(BINDIR)/yaml/cert-manager.yaml | $(BINDIR)/scratch/manifests-unsigned
	mkdir -p $(BINDIR)/scratch/manifests-unsigned/deploy/chart/
	mkdir -p $(BINDIR)/scratch/manifests-unsigned/deploy/manifests/
	cp $(BINDIR)/cert-manager-$(RELEASE_VERSION).tgz $(BINDIR)/scratch/manifests-unsigned/deploy/chart/
	cp $(BINDIR)/yaml/cert-manager.crds.yaml $(BINDIR)/yaml/cert-manager.yaml $(BINDIR)/scratch/manifests-unsigned/deploy/manifests/
	# removes leading ./ from archived paths
	find $(BINDIR)/scratch/manifests-unsigned -maxdepth 1 -mindepth 1 | sed 's|.*/||' | tar czf $@ -C $(BINDIR)/scratch/manifests-unsigned -T -
	rm -rf $(BINDIR)/scratch/manifests-unsigned

# This metadata blob is constructed slightly differently and doesn't use hack/artifact-metadata.template.json directly;
# this is because the bazel staged releases didn't include an "os" or "architecture" field for this artifact
$(BINDIR)/metadata/cert-manager-manifests.tar.gz.metadata.json: $(BINDIR)/release/cert-manager-manifests.tar.gz hack/artifact-metadata.template.json | $(BINDIR)/metadata
	jq -n --arg name "$(notdir $<)" \
		--arg sha256 "$(shell ./hack/util/hash.sh $<)" \
		'.name = $$name | .sha256 = $$sha256' > $@

################
# Helm Targets #
################

# These targets provide for building and signing the cert-manager helm chart.

$(BINDIR)/cert-manager-$(RELEASE_VERSION).tgz: $(BINDIR)/helm/cert-manager/README.md $(BINDIR)/helm/cert-manager/Chart.yaml $(BINDIR)/helm/cert-manager/values.yaml $(HELM_TEMPLATE_TARGETS) $(BINDIR)/helm/cert-manager/templates/NOTES.txt $(BINDIR)/helm/cert-manager/templates/_helpers.tpl $(BINDIR)/helm/cert-manager/templates/crds.yaml $(BINDIR)/tools/helm | $(BINDIR)/helm/cert-manager
	$(HELM_CMD) package --app-version=$(RELEASE_VERSION) --version=$(RELEASE_VERSION) --destination "$(dir $@)" ./$(BINDIR)/helm/cert-manager

$(BINDIR)/cert-manager-$(RELEASE_VERSION).tgz.prov: $(BINDIR)/cert-manager-$(RELEASE_VERSION).tgz | $(BINDIR)/helm/cert-manager $(BINDIR)/tools/cmrel
ifeq ($(strip $(CMREL_KEY)),)
	$(error Trying to sign helm chart but CMREL_KEY is empty)
endif
	cd $(dir $<) && $(CMREL) sign helm --chart-path "$(notdir $<)" --key "$(CMREL_KEY)"

$(BINDIR)/helm/cert-manager/templates/%.yaml: deploy/charts/cert-manager/templates/%.yaml | $(BINDIR)/helm/cert-manager/templates
	cp -f $^ $@

$(BINDIR)/helm/cert-manager/templates/_helpers.tpl: deploy/charts/cert-manager/templates/_helpers.tpl | $(BINDIR)/helm/cert-manager/templates
	cp $< $@

$(BINDIR)/helm/cert-manager/templates/NOTES.txt: deploy/charts/cert-manager/templates/NOTES.txt | $(BINDIR)/helm/cert-manager/templates
	cp $< $@

$(BINDIR)/helm/cert-manager/templates/crds.yaml: $(BINDIR)/scratch/yaml/cert-manager-crd-templates.yaml | $(BINDIR)/helm/cert-manager/templates
	echo '{{- if .Values.installCRDs }}' > $@
	cat $< >> $@
	echo '{{- end }}' >> $@

$(BINDIR)/helm/cert-manager/values.yaml: deploy/charts/cert-manager/values.yaml | $(BINDIR)/helm/cert-manager
	cp $< $@

$(BINDIR)/helm/cert-manager/README.md: deploy/charts/cert-manager/README.template.md | $(BINDIR)/helm/cert-manager
	sed -e "s:{{RELEASE_VERSION}}:$(RELEASE_VERSION):g" < $< > $@

$(BINDIR)/helm/cert-manager/Chart.yaml: deploy/charts/cert-manager/Chart.template.yaml deploy/charts/cert-manager/signkey_annotation.txt $(BINDIR)/tools/yq | $(BINDIR)/helm/cert-manager
	@# this horrible mess is taken from the YQ manual's example of multiline string blocks from a file:
	@# https://mikefarah.gitbook.io/yq/operators/string-operators#string-blocks-bash-and-newlines
	@# we set a bash variable called SIGNKEY_ANNOTATION using read, and then use that bash variable in yq
	IFS= read -rd '' SIGNKEY_ANNOTATION < <(cat deploy/charts/cert-manager/signkey_annotation.txt) ; \
		SIGNKEY_ANNOTATION=$$SIGNKEY_ANNOTATION $(BINDIR)/tools/yq eval \
		'.annotations."artifacthub.io/signKey" = strenv(SIGNKEY_ANNOTATION) | .annotations."artifacthub.io/prerelease" = "$(IS_PRERELEASE)" | .version = "$(RELEASE_VERSION)" | .appVersion = "$(RELEASE_VERSION)"' \
		$< > $@

#################################
# Targets for cert-manager.yaml #
#################################

# These targets depend on the cert-manager helm chart and the creation of the standalone CRDs.
# They use `helm template` to create a single static YAML manifest containing all resources
# with templating completed, and then concatenate with the cert-manager namespace and the CRDs.

$(BINDIR)/yaml/cert-manager.yaml: $(BINDIR)/scratch/license.yaml deploy/manifests/namespace.yaml $(BINDIR)/scratch/yaml/cert-manager.crds.unlicensed.yaml $(BINDIR)/scratch/yaml/cert-manager-static-resources.yaml | $(BINDIR)/yaml
	@# NB: filter-out removes the license (the first dependency, $<) from the YAML concatenation
	./hack/concat-yaml.sh $(filter-out $<, $^) | cat $< - > $@

# Renders all resources except the namespace and the CRDs
$(BINDIR)/scratch/yaml/cert-manager-static-resources.yaml: $(BINDIR)/cert-manager-$(RELEASE_VERSION).tgz $(BINDIR)/tools/helm | $(BINDIR)/scratch/yaml
	@# The sed command removes the first line but only if it matches "---", which helm adds
	$(HELM_CMD) template --api-versions="" --namespace=cert-manager --set="creator=static" --set="startupapicheck.enabled=false" cert-manager $< | \
		sed -e "1{/^---$$/d;}" > $@

######################################
# Targets for cert-manager.crds.yaml #
######################################

# These targets generate a dummy helm chart containing _only_ our CRDs, and then uses `helm template`
# to create a single YAML file containing all CRDS with the templating completed

# CRDs with a license
$(BINDIR)/yaml/cert-manager.crds.yaml: $(BINDIR)/scratch/license.yaml $(BINDIR)/scratch/yaml/cert-manager.crds.unlicensed.yaml | $(BINDIR)/yaml
	cat $^ > $@

$(BINDIR)/scratch/yaml/cert-manager.crds.unlicensed.yaml: $(BINDIR)/scratch/cert-manager-crds/cert-manager-$(RELEASE_VERSION).tgz $(BINDIR)/tools/helm | $(BINDIR)/scratch/yaml
	@# The sed command removes the first line but only if it matches "---", which helm adds
	$(HELM_CMD) template --api-versions="" --namespace=cert-manager --set="creator=static" --set="startupapicheck.enabled=false" cert-manager $< | \
		sed -e "1{/^---$$/d;}" > $@

$(BINDIR)/scratch/cert-manager-crds/cert-manager-$(RELEASE_VERSION).tgz: $(BINDIR)/helm/cert-manager-crds/templates/_helpers.tpl $(BINDIR)/helm/cert-manager-crds/templates/crd-templates.yaml $(BINDIR)/helm/cert-manager-crds/README.md $(BINDIR)/helm/cert-manager-crds/Chart.yaml $(BINDIR)/helm/cert-manager-crds/values.yaml $(BINDIR)/tools/helm | $(BINDIR)/scratch
	$(HELM_CMD) package --app-version=$(RELEASE_VERSION) --version=$(RELEASE_VERSION) --destination "$(dir $@)" ./$(BINDIR)/helm/cert-manager-crds

# create a temporary chart containing the cert-manager CRDs in order to use helm's
# templating engine to create usable CRDs for static installation
$(BINDIR)/helm/cert-manager-crds/Chart.yaml: deploy/charts/cert-manager/Chart.template.yaml | $(BINDIR)/helm/cert-manager-crds
	sed -e "s:{{IS_PRERELEASE}}:$(IS_PRERELEASE):g" \
		-e "s:{{RELEASE_VERSION}}:$(RELEASE_VERSION):g" < $< > $@

$(BINDIR)/helm/cert-manager-crds/README.md: | $(BINDIR)/helm/cert-manager-crds
	@echo "This chart is a cert-manager build artifact, do not use" > $@

$(BINDIR)/helm/cert-manager-crds/values.yaml: deploy/charts/cert-manager/values.yaml | $(BINDIR)/helm/cert-manager
	cp $< $@

$(BINDIR)/helm/cert-manager-crds/templates/_helpers.tpl: deploy/charts/cert-manager/templates/_helpers.tpl | $(BINDIR)/helm/cert-manager-crds/templates
	cp $< $@

$(BINDIR)/helm/cert-manager-crds/templates/crd-templates.yaml: $(BINDIR)/scratch/yaml/cert-manager-crd-templates.yaml | $(BINDIR)/helm/cert-manager-crds/templates
	cp $< $@

# Create a single file containing all CRDs before they've been templated.
$(BINDIR)/scratch/yaml/cert-manager-crd-templates.yaml: $(ALLCRDS) | $(BINDIR)/scratch/yaml
	./hack/concat-yaml.sh $^ > $@

.PHONY: templated-crds
templated-crds: $(BINDIR)/yaml/templated-crds/crd-challenges.templated.yaml $(BINDIR)/yaml/templated-crds/crd-orders.templated.yaml $(BINDIR)/yaml/templated-crds/crd-certificaterequests.templated.yaml $(BINDIR)/yaml/templated-crds/crd-clusterissuers.templated.yaml $(BINDIR)/yaml/templated-crds/crd-issuers.templated.yaml $(BINDIR)/yaml/templated-crds/crd-certificates.templated.yaml

$(BINDIR)/yaml/templated-crds/crd-challenges.templated.yaml $(BINDIR)/yaml/templated-crds/crd-orders.templated.yaml $(BINDIR)/yaml/templated-crds/crd-certificaterequests.templated.yaml $(BINDIR)/yaml/templated-crds/crd-clusterissuers.templated.yaml $(BINDIR)/yaml/templated-crds/crd-issuers.templated.yaml $(BINDIR)/yaml/templated-crds/crd-certificates.templated.yaml: $(BINDIR)/yaml/templated-crds/crd-%.templated.yaml: $(BINDIR)/yaml/cert-manager.yaml $(DEPENDS_ON_GO) | $(BINDIR)/yaml/templated-crds
	$(GO) run hack/extractcrd/main.go $< $* > $@

###############
# Dir targets #
###############

# These targets are trivial, to ensure that dirs exist

$(BINDIR)/yaml:
	@mkdir -p $@

$(BINDIR)/helm/cert-manager:
	@mkdir -p $@

$(BINDIR)/helm/cert-manager/templates:
	@mkdir -p $@

$(BINDIR)/helm/cert-manager-crds:
	@mkdir -p $@

$(BINDIR)/helm/cert-manager-crds/templates:
	@mkdir -p $@

$(BINDIR)/scratch/yaml:
	@mkdir -p $@

$(BINDIR)/scratch/manifests-unsigned:
	@mkdir -p $@

$(BINDIR)/scratch/manifests-signed:
	@mkdir -p $@

$(BINDIR)/yaml/templated-crds:
	@mkdir -p $@
