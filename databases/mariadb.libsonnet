local derCluster = import "../utils/derCluster.libsonnet";
local openshift = import "../utils/openshift.libsonnet";
{
  DOCUMENTATION: |||
    MariaDB SQL Datastore

    Parameters
    ~~~~~~~~~~

    :name:                          name to be used for the instance (default: mariadb)
    :project:                       name of the project, used for labeling purposes too - mandatory
    :rootPassword:                  password for the root user - mandatory
    :exporterPassword:              password for the exporter user (prometheus statisticts) - mandatory
    :databaseName (optional):       name of the database automatically created. defaults to "test"
    :username (optional):           name of the user automatically created.
    :password (optional):           password for the automatically created user.
    :resources (optional):          kubernetes resource specification for the mariadb container
    :resourcesExporter (optional):  kubernetes resource specification for the exporter container
    :version(optional):             docker MariaDB version, default 105 stands for MariaDB 10.5.x
    :versionRhel(optional):         RHEL version for which $version has been built, see https://catalog.redhat.com/software/containers/search
    :versionTagServer (optional):   docker image tag for the server, default is "latest"
    :versionTagExporter (optional): docker image for the mysql-exporter, default is "latest
    :storageSize (optional):        Size of the server pvc (default 1Gi)
    :storageClass (optional):       Storageclass of the server pvc (default: "default")
    :customMysqldConfig (optional): your custom mysql server config
    :appLabelList (optional):       List of app-labels to be affinite to, e.g.
  |||,
  EXAMPLES: [
    {
      caption: "Create a MariaDB Database",
      code: |||
        mariadb.mariadb("mariadb-staging") + {
          project: "foo",
          rootPassword: "hunter2",
          exporterPassword: "hunter2",
          storageSize: "10Gi",
        }
      |||,
    },
  ],
  mariadb(name):: {
    project:: error "project must be defined",
    rootPassword:: error "rootPassword must be definied",
    exporterPassword:: error "exporterPassword must be defined",
    version:: "105",
    versionRhel:: "rhel9",
    versionTagServer:: "latest",
    versionTagExporter:: "latest",
    storageSize:: "1Gi",
    databaseName:: null,
    username:: null,
    password:: null,
    storageClass:: null,
    appLabelList:: null,
    resources:: {
      limits: {
        cpu: 1,
        memory: "2Gi",
      },
      requests: {
        cpu: "200m",
        memory: "1Gi",
      },
    },
    resourcesExporter:: {
      limits: {
        cpu: "100m",
        memory: "500Mi",
      },
      requests: {
        cpu: "50m",
        memory: "100Mi",
      },
    },
    customMysqldConfig:: |||
      [mysqld]
    |||,

    local root = self,

    secret: derCluster.Secret(name) + {
      project: root.project,
      data: {
        "database-root-password": std.base64(root.rootPassword),
        "database-exporter-password": std.base64(root.exporterPassword),
        "exporter-data-source": std.base64("exporter:" + root.exporterPassword + "@(127.0.0.1:3306)/"),
      } + if root.databaseName != null && root.username != null && root.password != null then {
        "database-user-password": std.base64(root.password),
      } else {},
    },

    config: derCluster.ConfigMap(name) + {
      project: root.project,
      data: {
        "99-custom.cnf": root.customMysqldConfig,
        "init.sql": |||
          CREATE USER IF NOT EXISTS 'exporter'@'127.0.0.1' IDENTIFIED BY '${MYSQL_EXPORTER_PASSWORD}';
          ALTER USER 'exporter'@'127.0.0.1' IDENTIFIED BY '${MYSQL_EXPORTER_PASSWORD}';
          GRANT SELECT, PROCESS, REPLICATION CLIENT ON *.* TO 'exporter'@'127.0.0.1';
        |||,
      },
    },

    pvc: derCluster.PersistentVolumeClaim(name + "-pvc") + {
      project: root.project,
      storage: root.storageSize,
      spec+: if std.isString(root.storageClass) then {
        storageClassName: root.storageClass,
      } else {},
    },

    deployment: derCluster.DeploymentConfig(name) + {
      app_label: name,
      project: root.project,
      spec+: {
        strategy: {
          recreateParams: {
            post: {
              execNewPod: {
                command: [
                  "/bin/sh",
                  "-i",
                  "-c",
                  'sleep 10 && sed -e "s/\\${MYSQL_EXPORTER_PASSWORD}/$MYSQL_EXPORTER_PASSWORD/g" /config/init.sql | mysql -h ' + name + " -u root -p$MYSQL_ROOT_PASSWORD",
                ],
                containerName: name,
                env: [
                  { name: "MYSQL_EXPORTER_PASSWORD", valueFrom: openshift.SecretKeyRef(root.secret, "database-exporter-password") },
                ],
                volumes: [
                  "config",
                ],
              },
              failurePolicy: "ignore",
            },
          },
          type: "Recreate",
        },
        triggers+: [
          {
            type: "ConfigChange",
          },
          {
            type: "ImageChange",
            imageChangeParams: {
              automatic: true,
              from: {
                kind: "ImageStreamTag",
                name: name + "-server:" + root.versionTagServer,
              },
              containerNames: [
                name,
              ],
            },
          },
          {
            type: "ImageChange",
            imageChangeParams: {
              automatic: true,
              from: {
                kind: "ImageStreamTag",
                name: name + "-exporter:" + root.versionTagExporter,
              },
              containerNames: [
                "exporter",
              ],
            },
          },
        ],
        template+: {
          metadata+: {
            annotations+: {
              "prometheus.io/path": "/metrics",
              "prometheus.io/port": "9104",
              "prometheus.io/scrape": "true",
            },
          },
          spec+: {
            affinity+: if std.isString(root.appLabelList) then {
              podAntiAffinity: {
                preferredDuringSchedulingIgnoredDuringExecution: [
                  {
                    podAffinityTerm: {
                      labelSelector: {
                        matchExpressions: [
                          {
                            key: "app",
                            operator: "In",
                            values: root.appLabelList,
                          },
                        ],
                      },
                      topologyKey: "kubernetes.io/hostname",
                    },
                    weight: 100,
                  },
                ],
              },
            } else {},
            containers_: {
              default: openshift.Container(name) {
                image: " ",
                ports: [{ containerPort: 3306, name: name }],
                env_: {
                  MYSQL_ROOT_PASSWORD: openshift.SecretKeyRef(root.secret, "database-root-password"),
                  MYSQL_DATADIR_ACTION: "upgrade-auto",
                } + if root.databaseName != null && root.username != null && root.password != null then {
                  MYSQL_DATABASE: root.databaseName,
                  MYSQL_USER: root.username,
                  MYSQL_PASSWORD: openshift.SecretKeyRef(root.secret, "database-user-password"),
                } else {},
                livenessProbe: {
                  failureThreshold: 5,
                  initialDelaySeconds: 30,
                  periodSeconds: 10,
                  successThreshold: 1,
                  tcpSocket: {
                    port: 3306,
                  },
                  timeoutSeconds: 1,
                },
                readinessProbe: {
                  exec: {
                    command: [
                      "/bin/sh",
                      "-i",
                      "-c",
                      "/usr/bin/mysqladmin ping",
                    ],
                  },
                  failureThreshold: 5,
                  initialDelaySeconds: 5,
                  periodSeconds: 10,
                  successThreshold: 1,
                  timeoutSeconds: 1,
                },
                resources: root.resources,
                volumeMounts: [
                  {
                    mountPath: "/var/lib/mysql/data",
                    name: "data",
                  },
                  {
                    mountPath: "/config",
                    name: "config",
                  },
                  {
                    mountPath: "/etc/my.cnf.d/99-custom.cnf",
                    name: "config",
                    subPath: "99-custom.cnf",
                  },
                ],
              },
              exporter: openshift.Container("exporter") {
                args: [
                  "--collect.info_schema.innodb_metrics",
                  "--collect.info_schema.innodb_tablespaces",
                  "--collect.info_schema.innodb_cmp",
                  "--collect.info_schema.innodb_cmpmem",
                  "--collect.engine_innodb_status",
                  "--collect.perf_schema.tablelocks",
                  "--collect.perf_schema.tableiowaits",
                  "--collect.perf_schema.indexiowaits",
                  "--collect.perf_schema.eventswaits",
                  "--collect.info_schema.tablestats",
                  "--collect.info_schema.userstats",
                  "--collect.info_schema.clientstats",
                  "--collect.info_schema.processlist",
                  "--collect.info_schema.tables",
                ],
                env_: {
                  MYSQL_USER: "exporter",
                  MYSQL_HOST: "127.0.0.1",
                  MYSQL_PASSWORD: openshift.SecretKeyRef(root.secret, "database-exporter-password"),
                  DATA_SOURCE_NAME: openshift.SecretKeyRef(root.secret, "exporter-data-source"),
                },
                image: " ",
                livenessProbe: {
                  failureThreshold: 3,
                  initialDelaySeconds: 5,
                  periodSeconds: 10,
                  successThreshold: 1,
                  tcpSocket: {
                    port: 9104,
                  },
                  timeoutSeconds: 1,
                },
                ports: [{ containerPort: 9104, name: "exporter" }],
                readinessProbe: {
                  failureThreshold: 3,
                  httpGet: {
                    path: "/metrics",
                    port: 9104,
                    scheme: "HTTP",
                  },
                  initialDelaySeconds: 15,
                  periodSeconds: 10,
                  successThreshold: 1,
                  timeoutSeconds: 5,
                },
                resources: root.resourcesExporter,
              },
            },
            volumes_: {
              data: openshift.PersistentVolumeClaimVolume(root.pvc),
              config: openshift.ConfigMapVolume(root.config),
            },
          },
        },
      },
    },

    imagestream_mysql_exporter: derCluster.ImageStream(name + "-exporter") + {
      project: root.project,
      metadata+: {
        labels+: {
          "cloudflight.io/imagesource": "docker.io_prom_mysqld-exporter",
        },
      },
      spec: {
        tags: [
          {
            name: root.versionTagExporter,
            from: {
              kind: "DockerImage",
              name: "docker.io/prom/mysqld-exporter:" + root.versionTagExporter,
            },
          },
        ],
      },
    },

    imagestream_myql_server: derCluster.ImageStream(name + "-server") + {
      project: root.project,
      metadata+: {
        labels+: {
          "cloudflight.io/imagesource": "registry.redhat.io_" + root.versionRhel + "_mariadb-" + root.version,
        },
      },
      spec: {
        tags: [
          {
            name: root.versionTagServer,
            from: {
              kind: "DockerImage",
              name: "registry.redhat.io/" + root.versionRhel + "/mariadb-" + root.version + ":" + root.versionTagServer,
            },
          },
        ],
      },
    },

    service: derCluster.Service(name) + {
      project: root.project,
      target_pod: root.deployment.spec.template,
    },
  },
}
