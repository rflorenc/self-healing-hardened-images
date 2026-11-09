# METADATA
# title: BO1122 demo release policy
# description: Release checks on top of Conforma's built-in signature checks, from the SLSA provenance Tekton Chains signs.
package cve_demo

import rego.v1

_provenance := [s |
	some att in input.attestations
	s := att.statement
	s.predicateType in {"https://slsa.dev/provenance/v0.2", "https://slsa.dev/provenance/v1"}
	s.predicate.builder.id == "https://tekton.dev/chains/v2"
]

_labels(s) := object.get(s.predicate, ["invocation", "environment", "labels"], {})

_rule_data(key) := data.rule_data[key]

# METADATA
# title: SLSA provenance from Tekton Chains
# description: The image carries a signed SLSA provenance attestation written by Tekton Chains.
# custom:
#   short_name: provenance_present
#   failure_msg: No SLSA provenance attestation from Tekton Chains
deny contains result if {
	count(_provenance) == 0
	result := {"code": "cve_demo.provenance_present", "msg": "No SLSA provenance attestation from Tekton Chains"}
}

# METADATA
# title: Built by the trusted pipeline
# description: The provenance names the expected pipeline and pipeline task.
# custom:
#   short_name: trusted_pipeline
#   failure_msg: Image was not built by the expected pipeline task
deny contains result if {
	count(_provenance) > 0
	not _built_by_trusted_pipeline
	result := {
		"code": "cve_demo.trusted_pipeline",
		"msg": sprintf("Image was not built by pipeline %q, task %q", [_rule_data("pipeline"), _rule_data("pipeline_task")]),
	}
}

_built_by_trusted_pipeline if {
	some s in _provenance
	_labels(s)["tekton.dev/pipeline"] == _rule_data("pipeline")
	_labels(s)["tekton.dev/pipelineTask"] == _rule_data("pipeline_task")
}

# METADATA
# title: Built with the Red Hat build task
# description: The build ran the buildah task shipped with OpenShift Pipelines, not a modified copy.
# custom:
#   short_name: trusted_build_task
#   failure_msg: Image was not built with the trusted buildah task
deny contains result if {
	count(_provenance) > 0
	not _trusted_task
	result := {
		"code": "cve_demo.trusted_build_task",
		"msg": sprintf("Image was not built with a task from %q", [_rule_data("trusted_task_prefix")]),
	}
}

_trusted_task if {
	some s in _provenance
	startswith(s.predicate.invocation.configSource.uri, _rule_data("trusted_task_prefix"))
}
