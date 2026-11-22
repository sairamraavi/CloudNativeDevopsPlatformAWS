"""Offline tests for destructive boundaries and captured dev restore settings."""

import contextlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / "scripts/dev-session.py"
spec = importlib.util.spec_from_file_location("dev_session", path)
session = importlib.util.module_from_spec(spec)
spec.loader.exec_module(session)


class LifecycleTests(unittest.TestCase):
    def test_changed_vpc_blocks_cleanup(self):
        with tempfile.TemporaryDirectory() as td, patch.object(
            session, "outputs", return_value={"vpc_id": "different"}
        ), patch.object(session, "helm") as helm:
            with self.assertRaisesRegex(ValueError, "VPC differs"):
                session.teardown({"old": {"vpc_id": "original"}}, Path(td), Path(td))
            helm.assert_not_called()

    def test_changed_image_blocks_restore(self):
        with patch.object(
            session,
            "aws",
            return_value={"imageDetails": [{"imageDigest": "different"}]},
        ):
            with self.assertRaisesRegex(ValueError, "digest changed"):
                session.check_images(
                    {"frontend": {"tag": "published", "digest": "expected"}}
                )

    def test_restore_preserves_frontend_tag_and_refreshes_scrape_address(self):
        with tempfile.TemporaryDirectory() as td, contextlib.ExitStack() as stack:
            tmp = Path(td)
            live = {
                "vpc_id": "new-vpc",
                "nat_public_ips": {"zone-a": "1.2.3.4"},
                "eks_cluster_name": "current",
                "secret_reader_role_arn": "reader",
                "load_balancer_controller_role_arn": "lbc",
                "autoscaler_role_arn": "scaler",
                "media_workload_role_arns": {},
                "application_logs_role_arn": "logger",
                "jenkins_private_ip": "10.0.9.55",
            }
            releases = {
                key: {"version": "pinned", "values": {}} for key in session.RELEASES
            }
            releases["monitoring"]["values"] = {
                "prometheus": {
                    "prometheusSpec": {
                        "additionalScrapeConfigs": [
                            {
                                "job_name": "jenkins",
                                "static_configs": [{"targets": ["old-ip:8082"]}],
                            }
                        ]
                    }
                }
            }
            m = {
                "account": "acct",
                "snapshots": {"grafana": "snap"},
                "zone": "zone",
                "domain": "app.example",
                "atlas": "project",
                "region": "ap-south-1",
                "alertConfig": {},
                "releases": releases,
                "images": {
                    name: {"tag": "hotfix" if name == "frontend" else "backend-release"}
                    for name in session.SERVICES
                },
                "grafana-admin": {},
                "alertmanager-ses-smtp": {},
                "dns": {"type": "CNAME"},
            }
            installs = {}

            def helm(*args, **kwargs):
                if args[0] == "upgrade":
                    installs[args[2]] = json.loads(
                        args[args.index("-f") + 1].read_text()
                    )

            def mock(name, **kwargs):
                return stack.enter_context(patch.object(session, name, **kwargs))

            stack.enter_context(
                patch.object(
                    session.subprocess,
                    "run",
                    return_value=type("Result", (), {"returncode": 0})(),
                )
            )
            for name in (
                "check_images",
                "connect",
                "atlas",
                "dns",
                "verify_ssh",
                "run",
                "restore_storage",
                "apply",
                "k",
            ):
                mock(name)
            mock(
                "aws",
                return_value={"Snapshots": [{"State": "completed", "OwnerId": "acct"}]},
            )
            mock("outputs", return_value=live)
            mock("plan", return_value="plan")
            mock("helm", side_effect=helm)
            mock("tf", return_value="")
            mock("records", return_value=[])
            mock("atlas_entries", return_value={})
            mock(
                "resource",
                return_value={
                    "status": {"loadBalancer": {"ingress": [{"hostname": "new-alb"}]}}
                },
            )
            session.restore(
                m,
                tmp,
                {
                    "repository_urls": {"auth": "registry/auth"},
                    "media_bucket_name": "media",
                    "application_certificate_arn": "cert",
                },
                tmp,
            )
            self.assertEqual(set(installs), set(session.RELEASES))
            self.assertEqual(installs["streamingapp"]["frontend"]["tag"], "hotfix")
            self.assertEqual(
                installs["streamingapp"]["image"]["tag"], "backend-release"
            )
            monitor = installs["monitoring"]
            self.assertEqual(
                monitor["prometheus"]["prometheusSpec"]["additionalScrapeConfigs"][0][
                    "static_configs"
                ][0]["targets"],
                ["10.0.9.55:8082"],
            )
            self.assertEqual(
                monitor["alertmanager"]["alertmanagerSpec"][
                    "alertmanagerConfiguration"
                ]["name"],
                "capstone-email",
            )


if __name__ == "__main__":
    unittest.main()
