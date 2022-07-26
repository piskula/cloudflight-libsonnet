local k = (import 'cloudflight-libsonnet/prelude.libsonnet');
{
  _config+:: {
    myApplication: {
      name: 'my-application',
      image: error '$._config.myApplication.image must be defined',
    },
  },
  myApplication: {
    deployment: k.util.java.deployment.new(
      name=$._config.myApplication.name,
      image=$._config.myApplication.image
    ),
    service: k.util.serviceFor(self.deployment),
    route: k.util.routeFor(self.service, 'hello.example.com'),
  },
}
