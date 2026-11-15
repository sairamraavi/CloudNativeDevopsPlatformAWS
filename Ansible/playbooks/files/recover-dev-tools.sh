#!/usr/bin/env bash
set -euo pipefail
umask 077
backup=${1:?backup directory required}
exec 9>/run/lock/capstone-tools-restore.lock
flock -n 9 || { echo 'Another restore is in progress' >&2; exit 1; }

# Each private file is installed atomically. Keep operator-supplied values.
restore_file() (
  archive_path=$1
  destination=/$archive_path
  [[ -s $destination ]] && exit 0
  mkdir -p "$(dirname "$destination")"
  temporary=$(mktemp "${destination}.XXXXXX")
  trap 'rm -f "$temporary"' EXIT
  tar -xOzf "$backup/host-private-config.tar.gz" "$archive_path" > "$temporary"
  test -s "$temporary"
  mv "$temporary" "$destination"
)

install -d -m 700 /etc/cloudflared
restore_file etc/cloudflared/token
restore_file opt/capstone-sonarqube/compose.yaml
restore_file opt/capstone-sonarqube/.env

live=/var/lib/jenkins
previous=/var/lib/jenkins-before-restore
job=jobs/streamingapp-dev/config.xml
if [[ ! -s "$live/$job" ]]; then
  if [[ -e "$previous" || ! -d "$live" ]] || [[ -n $(find "$live/jobs" -name config.xml -print -quit 2>/dev/null) ]]; then
    echo 'Existing Jenkins jobs or an interrupted switch require inspection.' >&2
    exit 1
  fi
  stage=$(mktemp -d /var/lib/jenkins-restore.XXXXXX)
  trap 'rm -rf -- "$stage"' EXIT
  tar -xzf "$backup/jenkins-home.tar.gz" -C "$stage" --strip-components=1 --no-same-owner
  for entry in config.xml "$job" secrets/master.key secrets/hudson.util.Secret; do
    test -s "$stage/$entry"
  done
  chown -hR jenkins:jenkins "$stage"
  systemctl stop jenkins
  if ! mv "$live" "$previous"; then systemctl start jenkins; exit 1; fi
  if ! mv "$stage" "$live"; then mv "$previous" "$live"; systemctl start jenkins; exit 1; fi
  if ! systemctl start jenkins; then
    systemctl stop jenkins
    mv "$live" "$live.failed-$(date +%s)"
    mv "$previous" "$live"
    systemctl start jenkins
    exit 1
  fi
fi

cd /opt/capstone-sonarqube
docker compose config --quiet
printf 'vm.max_map_count=1048576\n' > /etc/sysctl.d/99-capstone-sonarqube.conf
sysctl -p /etc/sysctl.d/99-capstone-sonarqube.conf
docker compose up -d --wait --wait-timeout 180 db
tables=$(docker compose exec -T db psql -U sonar -d sonar -Atc \
  "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');")
case "$tables" in
  0)
    docker compose exec -T db pg_restore --username=sonar --dbname=sonar \
      --no-owner --no-privileges --single-transaction --exit-on-error < "$backup/sonarqube.dump"
    ;;
  ''|*[!0-9]*) echo 'Unable to verify database contents' >&2; exit 1 ;;
  *) echo 'Keeping populated SonarQube database' ;;
esac
if [[ -z $(docker compose ps -q --status running sonarqube) ]]; then
  docker compose run --rm -T --no-deps --entrypoint sh sonarqube \
    -ec 'cd /opt/sonarqube/extensions && tar --skip-old-files --no-same-owner -xzf -' \
    < "$backup/sonarqube-extensions.tar.gz"
fi
docker compose up -d sonarqube
