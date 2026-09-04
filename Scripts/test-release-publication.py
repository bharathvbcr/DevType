#!/usr/bin/env python3
"""Exercise the real publisher against a local Git remote and a stateful gh double."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TAG = "v0.1.4"
DMG = "DevType-0.1.4.dmg"

GH_DOUBLE = r'''
import json, os, pathlib, sys
p = pathlib.Path(os.environ["RELEASE_TEST_STATE"])
s = json.loads(p.read_text())
a = sys.argv[1:]
s["calls"].append(a)
def finish(code=0):
    p.write_text(json.dumps(s))
    sys.exit(code)
def option(name):
    return a[a.index(name) + 1]
def fail(message):
    print(message, file=sys.stderr)
    finish(1)
mode = s["mode"]
if a[0] == "api":
    if mode == "api_failure": fail("HTTP 503: service unavailable")
    if "--paginate" not in a: fail("release inventory must be paginated")
    if mode == "malformed_state": print("null")
    elif s["exists"]: print(str(s["draft"]).lower())
elif a[:2] == ["release", "create"]:
    if "--draft" not in a or "--verify-tag" not in a: fail("unsafe creation")
    if s["exists"]: fail("release already exists")
    s.update(exists=True, draft=True, body=pathlib.Path(option("--notes-file")).read_text(), assets=[])
elif a[:2] == ["release", "edit"]:
    if "--draft=false" in a:
        if mode == "publish_failure": fail("publish failed")
        s["draft"] = False
    else:
        s["body"] = pathlib.Path(option("--notes-file")).read_text()
elif a[:2] == ["release", "upload"]:
    s["uploads"] = s.get("uploads", 0) + 1
    if not s["draft"]: fail("attempted to overwrite a public asset")
    if mode == "upload_failure" or (mode == "transient_upload" and s["uploads"] < 3):
        fail("upload failed")
    s["assets"] = ["DevType-0.1.4.dmg"]
    if mode == "extra_asset": s["assets"].append("stale.zip")
elif a[:2] == ["release", "view"]:
    if mode == "view_failure": fail("metadata unavailable")
    body = s["body"]
    if mode == "body_mismatch": body += "changed"
    if mode == "body_newline": body += "\n"
    value = dict(tagName="v0.1.4", name="DevType v0.1.4", isDraft=s["draft"],
                 isPrerelease=False, body=body, assets=[dict(name=n) for n in s["assets"]])
    if mode == "wrong_tag": value["tagName"] = "v0.1.3"
    if mode == "wrong_title": value["name"] = "Wrong title"
    if mode == "prerelease": value["isPrerelease"] = True
    if mode == "null_draft": value["isDraft"] = None
    if mode == "public_during_verification": value["isDraft"] = False
    if mode == "no_assets": value["assets"] = []
    if mode == "malformed_metadata": print("not json")
    else: print(json.dumps(value))
elif a[:2] == ["run", "list"]:
    if mode == "run_list_failure": fail("gh run list unavailable")
    for status in s.get("release_runs", []): print(status)
elif a[:2] == ["release", "download"]:
    s["downloads"] += 1
    if mode == "download_failure" or (mode == "transient_download" and s["downloads"] < 3):
        fail("download failed")
    data = b"valid fixture DMG"
    if mode == "corrupt_download" or (mode == "corrupt_public_download" and not s["draft"]):
        data = b"corrupt download"
    pathlib.Path(option("--dir"), option("--pattern")).write_bytes(data)
else:
    fail("unexpected gh command: " + repr(a))
finish()
'''


class ReleaseWorkflowTests(unittest.TestCase):
    def test_publication_depends_on_full_ci(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        release_job = workflow.split("\n  release:\n", 1)[1]
        self.assertIn("needs: [ci]", release_job)
        self.assertIn("uses: ./.github/workflows/ci.yml", workflow)
        ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.assertIn("workflow_call:", ci)
        self.assertIn("needs: [test, test-macos26]", ci)
        # Reusable workflows inherit github.workflow from the caller. A distinct
        # group avoids cancelling/deadlocking the parent Release workflow.
        self.assertIn("group: ci-${{ github.workflow }}-${{ github.ref }}", ci)

    def test_workflow_uses_the_tested_publication_owner(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertNotIn("softprops/action-gh-release", workflow)
        self.assertIn('./Scripts/publish-release.sh "${GITHUB_REF_NAME}"', workflow)
        self.assertIn("test-release-publication.py", (ROOT / "Scripts/ci-local.sh").read_text())


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="devtype-publication-")
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        shutil.copytree(ROOT / "Scripts", self.repo / "Scripts")
        notes = self.repo / "docs/releases"
        notes.mkdir(parents=True)
        (notes / f"{TAG}.md").write_text("# DevType v0.1.4\n\nCurated notes.\n")
        (self.repo / ".gitignore").write_text("dist/\n")
        self.git("init", "-q")
        self.git("config", "user.name", "Release Test")
        self.git("config", "user.email", "release@example.invalid")
        self.git("add", ".")
        self.git("commit", "-qm", "release fixture")
        self.git("tag", "-a", TAG, "-m", TAG)
        self.remote = self.base / "remote.git"
        self.git("init", "--bare", "-q", str(self.remote))
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "-q", "origin", f"refs/tags/{TAG}")
        dist = self.repo / "dist"
        dist.mkdir()
        (dist / DMG).write_bytes(b"valid fixture DMG")
        self.state_path = self.base / "state.json"
        self.state = dict(mode="ok", calls=[], downloads=0, exists=False, draft=True,
                          body="old notes", assets=[], release_runs=[])
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        for name, code in (("gh", GH_DOUBLE), ("sleep", "pass\n")):
            path = bin_dir / name
            path.write_text(f"#!{sys.executable}\n" + code)
            path.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
                        GH_REPO="release-test/fixture", RELEASE_TEST_STATE=str(self.state_path))

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, check=True,
                              capture_output=True, text=True).stdout.strip()

    def publish(self, mode="ok", success=True, release_runs=None, extra_env=None):
        self.state["mode"] = mode
        if release_runs is not None:
            self.state["release_runs"] = release_runs
        self.state_path.write_text(json.dumps(self.state))
        env = dict(self.env, **(extra_env or {}))
        # The guard must behave like a developer's shell, not like a workflow runner.
        env.pop("GITHUB_ACTIONS", None)
        result = subprocess.run(["bash", "Scripts/publish-release.sh", TAG, "dist"],
                                cwd=self.repo, env=env, capture_output=True,
                                text=True, timeout=20)
        self.state = json.loads(self.state_path.read_text())
        output = result.stdout + result.stderr
        if success:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
        return output

    def assert_not_published(self):
        self.assertTrue(self.state["draft"])
        self.assertFalse(any("--draft=false" in c for c in self.state["calls"]))

    def test_publish_only_after_verified_download(self):
        self.publish()
        calls = self.state["calls"]
        publish = next(i for i, c in enumerate(calls) if "--draft=false" in c)
        self.assertTrue(any(c[:2] == ["release", "download"] for c in calls[:publish]))
        self.assertTrue(any(c[:2] == ["release", "download"] for c in calls[publish + 1:]))
        self.assertFalse(self.state["draft"])

    def test_failed_draft_can_be_retried(self):
        self.publish("upload_failure", success=False)
        self.assert_not_published()
        self.publish()
        self.assertEqual(sum(c[:2] == ["release", "create"] for c in self.state["calls"]), 1)

    def test_in_flight_release_workflow_blocks_a_manual_publish(self):
        """The Release workflow publishes on tag push. A second publisher racing it leaves
        whichever one loses dying on an immutable release that is actually fine."""
        output = self.publish(release_runs=["in_progress"], success=False)
        self.assertIn("already in flight", output)
        self.assert_not_published()
        # Refused before mutating anything: only read-only lookups may have happened.
        self.assertTrue(all(c[0] in ("api", "run") for c in self.state["calls"]),
                        self.state["calls"])

    def test_a_finished_release_run_does_not_block_publishing(self):
        self.publish(release_runs=["completed", "completed"])
        self.assertFalse(self.state["draft"])

    def test_concurrent_publish_can_be_overridden_explicitly(self):
        self.publish(release_runs=["in_progress"],
                     extra_env={"DEVTYPE_ALLOW_CONCURRENT_PUBLISH": "1"})
        self.assertFalse(self.state["draft"])

    def test_an_unreadable_run_list_never_blocks_a_release(self):
        """Fail-open on purpose: a guard that cannot read the truth must not be the thing
        that stops a release."""
        output = self.publish(mode="run_list_failure")
        self.assertIn("could not check for an in-flight Release workflow", output)
        self.assertFalse(self.state["draft"])

    def test_published_release_is_never_overwritten(self):
        self.state.update(exists=True, draft=False)
        self.assertIn("already published", self.publish(success=False))
        self.assertTrue(all(c[0] == "api" for c in self.state["calls"]))

    def test_corrupt_or_unverifiable_drafts_remain_unpublished(self):
        for mode in ("api_failure", "malformed_state", "view_failure", "malformed_metadata",
                     "body_mismatch", "body_newline", "extra_asset", "no_assets", "wrong_tag",
                     "wrong_title", "prerelease", "null_draft", "public_during_verification",
                     "corrupt_download", "publish_failure"):
            with self.subTest(mode=mode):
                self.state.update(exists=False, draft=True, calls=[], downloads=0, assets=[])
                self.publish(mode, success=False)
                self.assertTrue(self.state["draft"])
                if mode != "publish_failure":
                    self.assert_not_published()

    def test_download_retries_are_bounded(self):
        self.publish("download_failure", success=False)
        self.assertEqual(self.state["downloads"], 5)
        self.assert_not_published()

    def test_transient_download_recovers(self):
        self.publish("transient_download")
        self.assertEqual(self.state["downloads"], 4)

    def test_transient_upload_recovers(self):
        self.publish("transient_upload")
        self.assertEqual(self.state.get("uploads"), 3)
        self.assertFalse(self.state["draft"])

    def test_public_verification_failure_is_not_success(self):
        self.publish("corrupt_public_download", success=False)
        self.assertFalse(self.state["draft"])

    def test_missing_remote_tag_cannot_be_created_by_publication(self):
        self.git("--git-dir", str(self.remote), "update-ref", "-d", f"refs/tags/{TAG}")
        self.publish(success=False)
        self.assertEqual(self.state["calls"], [])

    def test_moved_remote_tag_is_rejected(self):
        self.git("commit", "--allow-empty", "-qm", "other commit")
        self.git("push", "-q", "origin", f"+HEAD:refs/tags/{TAG}")
        self.git("checkout", "-q", TAG)
        self.publish(success=False)
        self.assertEqual(self.state["calls"], [])

    def test_dirty_source_is_rejected(self):
        (self.repo / "uncommitted.txt").write_text("uncommitted")
        self.publish(success=False)
        self.assertEqual(self.state["calls"], [])


if __name__ == "__main__":
    unittest.main()
