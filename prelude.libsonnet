(import 'ksonnet-util/kausal.libsonnet') +
(import 'utils.libsonnet') +
{
  local appsExtentions = {
    deployment+: {
      new(name, replicas, containers, podLabels={})::
        super.new(name, replicas, containers, podLabels)
        + (if $._config.project != null then super.metadata.withLabels({
          'cloudflight.io/project': $._config.project,
        }) else {})
    },
  },
  apps+: {
    v1beta1+: appsExtentions,
    v1+: appsExtentions,
  },
}
