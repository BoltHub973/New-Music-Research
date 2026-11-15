import ast
import datetime
import io
import json
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from tidalapi.playlist import ItemOrder, OrderDirection

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT))

import export_to_spotify
import track_playlists

# Never write to the user's live HUD progress file during automated tests.
track_playlists.km.PROGRESS_FILE = Path("/tmp/nmr-test-progress.json")
export_to_spotify.km.PROGRESS_FILE = Path("/tmp/nmr-test-progress.json")


class _DummyProgress:
    def add_task(self, *args, **kwargs):
        return 1

    def update(self, *args, **kwargs):
        pass

    def remove_task(self, *args, **kwargs):
        pass

    def advance(self, *args, **kwargs):
        pass


class _FakeSpotifyClient:
    """In-memory Spotipy stand-in that tracks playlist mutations and can inject drift."""

    def __init__(self, search_map, corrupt_after_add=False, persist_corruption=False):
        self.search_map = search_map
        self.corrupt_after_add = corrupt_after_add
        self.persist_corruption = persist_corruption
        self.playlists = {}
        self.add_calls = []
        self.replace_calls = []

    def me(self):
        return {"id": "test-user"}

    def search(self, q, limit=5, type="track"):
        for title, item in self.search_map.items():
            if title.lower() in q.lower():
                return {"tracks": {"items": [item]}}
        return {"tracks": {"items": []}}

    def user_playlist_create(self, user, name, public=False):
        pid = f"pl_{len(self.playlists) + 1}"
        self.playlists[pid] = []
        return {"id": pid, "name": name}

    def playlist_add_items(self, playlist_id, items):
        self.add_calls.append(list(items))
        self.playlists[playlist_id].extend(items)
        if self.corrupt_after_add:
            self.playlists[playlist_id] = list(reversed(self.playlists[playlist_id]))
            self.corrupt_after_add = False

    def playlist_replace_items(self, playlist_id, items):
        self.replace_calls.append(list(items))
        if self.persist_corruption:
            self.playlists[playlist_id] = list(reversed(items))
        else:
            self.playlists[playlist_id] = list(items)

    def playlist_items(self, playlist_id, limit=100, offset=0, fields=None):
        stored = self.playlists.get(playlist_id, [])
        chunk = stored[offset:offset + limit]
        has_next = (offset + len(chunk)) < len(stored)
        return {
            "items": [{"track": {"uri": uri}} for uri in chunk],
            "next": "more" if has_next else None,
            "total": len(stored),
        }

    def playlist_upload_cover_image(self, playlist_id, image_b64):
        pass


class TidalOrderAndGuardTests(unittest.TestCase):
    def test_fetch_playlist_requests_date_descending_across_pages(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        recent_dt = now - datetime.timedelta(days=1)

        def mk_track(name, tid):
            return SimpleNamespace(
                id=tid,
                name=name,
                artists=[SimpleNamespace(name="Artist")],
                album=SimpleNamespace(name="Album", cover=None, video_cover=None),
                date_added=recent_dt,
            )

        page1 = [mk_track(f"Track {i}", i) for i in range(100)]
        page2 = [mk_track("Track 100", 100)]
        calls = []

        class _FakePlaylist:
            num_tracks = 101

            def tracks(self, limit=None, offset=0, order=None, order_direction=None):
                calls.append((limit, offset, order, order_direction))
                if offset == 0:
                    return page1
                if offset == 100:
                    return page2
                return []

        class _FakeSession:
            def playlist(self, uuid):
                return _FakePlaylist()

        result = track_playlists.fetch_playlist(
            _FakeSession(),
            {"name": "Rap Bars & Melodies", "url": "https://tidal.com/playlist/test-uuid"},
            _DummyProgress(),
            0,
            (now - datetime.timedelta(days=7), None),
        )

        self.assertEqual(len(result), 101)
        self.assertEqual(result[0]["Title"], "Track 0")
        self.assertEqual(result[100]["Title"], "Track 100")
        self.assertEqual(len(calls), 3)
        for limit, offset, order, direction in calls:
            self.assertEqual(order, ItemOrder.Date)
            self.assertEqual(direction, OrderDirection.Descending)

    def test_source_guard_all_tidal_tracks_calls_sort_by_date_desc(self):
        """Fail if any .tracks(...) call omits ItemOrder.Date + OrderDirection.Descending."""
        py_files = [p for p in REPO_ROOT.glob("*.py") if p.is_file()]
        found_calls = 0
        for path in py_files:
            tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
            for node in ast.walk(tree):
                if (
                    isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "tracks"
                ):
                    found_calls += 1
                    kw = {k.arg: ast.unparse(k.value) for k in node.keywords if k.arg}
                    self.assertEqual(
                        kw.get("order"),
                        "ItemOrder.Date",
                        f"{path.name}:{node.lineno} must pass order=ItemOrder.Date",
                    )
                    self.assertEqual(
                        kw.get("order_direction"),
                        "OrderDirection.Descending",
                        f"{path.name}:{node.lineno} must pass order_direction=OrderDirection.Descending",
                    )
        self.assertGreater(found_calls, 0)

    def test_dedupe_tracks_preserves_left_to_right_priority(self):
        raw = [
            {"Title": "Party With The Boys", "Artist": "Don Toliver", "Album": "Single", "Source Playlist": "Rap Bars & Melodies"},
            {"Title": "To Begin With", "Artist": "Lil Jordan", "Album": "To Begin With", "Source Playlist": "Rap Bars & Melodies"},
            {"Title": "party with the boys", "Artist": "  Don  Toliver ", "Album": "Album Ver", "Source Playlist": "Thoro Hip-Hop"},
            {"Title": "Sarah!", "Artist": "Conway The Machine", "Album": "Sarah!", "Source Playlist": "Thoro Hip-Hop"},
        ]
        deduped = track_playlists.dedupe_tracks(raw)
        self.assertEqual(
            [t["Title"] for t in deduped],
            ["Party With The Boys", "To Begin With", "Sarah!"],
        )
        self.assertEqual(deduped[0]["Source Playlist"], "Rap Bars & Melodies")
        self.assertEqual(deduped[0]["Playlist Count"], 2)
        self.assertEqual(deduped[1]["Playlist Count"], 1)


class SpotifyAuditAndRepairTests(unittest.TestCase):
    def test_audit_passes_across_multiple_pages(self):
        expected = [f"spotify:track:{i}" for i in range(135)]
        fake_sp = _FakeSpotifyClient({})
        pid = fake_sp.user_playlist_create("u", "test")["id"]
        fake_sp.playlist_add_items(pid, expected[:100])
        fake_sp.playlist_add_items(pid, expected[100:])

        count, repaired = export_to_spotify.audit_and_repair_playlist(fake_sp, pid, expected)
        self.assertEqual(count, 135)
        self.assertFalse(repaired)
        self.assertEqual(fake_sp.replace_calls, [])

    def test_audit_repairs_drifted_order_and_paginates_replace(self):
        expected = [f"spotify:track:{i}" for i in range(125)]
        fake_sp = _FakeSpotifyClient({})
        pid = fake_sp.user_playlist_create("u", "test")["id"]
        fake_sp.playlists[pid] = list(reversed(expected))

        count, repaired = export_to_spotify.audit_and_repair_playlist(fake_sp, pid, expected)
        self.assertEqual(count, 125)
        self.assertTrue(repaired)
        self.assertEqual(fake_sp.playlists[pid], expected)
        self.assertEqual(len(fake_sp.replace_calls[0]), 100)
        self.assertEqual(fake_sp.add_calls[0], expected[100:])

    def test_audit_raises_if_order_still_wrong_after_repair(self):
        expected = ["spotify:track:1", "spotify:track:2", "spotify:track:3"]
        fake_sp = _FakeSpotifyClient({}, persist_corruption=True)
        pid = fake_sp.user_playlist_create("u", "test")["id"]
        fake_sp.playlists[pid] = list(reversed(expected))

        with self.assertRaises(RuntimeError):
            export_to_spotify.audit_and_repair_playlist(fake_sp, pid, expected)

    def test_exporter_dedupes_uris_repairs_drift_and_fails_loudly_on_bad_audit(self):
        search_map = {
            "Song A": {"uri": "spotify:track:A", "name": "Song A", "explicit": True, "artists": [{"name": "Artist 1"}]},
            "Song B": {"uri": "spotify:track:A", "name": "Song A", "explicit": True, "artists": [{"name": "Artist 1"}]},
            "Song C": {"uri": "spotify:track:C", "name": "Song C", "explicit": True, "artists": [{"name": "Artist 2"}]},
        }
        tracks_in = [
            {"Title": "Song A", "Artist": "Artist 1", "Album": "X", "Source Playlist": "P1"},
            {"Title": "Song B", "Artist": "Artist 1", "Album": "Y", "Source Playlist": "P2"},
            {"Title": "Song C", "Artist": "Artist 2", "Album": "Z", "Source Playlist": "P2"},
        ]

        # 1) Auto-repair succeeds when Spotify initially returns reversed order
        fake_ok = _FakeSpotifyClient(search_map, corrupt_after_add=True)
        out = io.StringIO()
        with patch.object(export_to_spotify, "get_credentials", return_value=True), \
             patch.object(export_to_spotify, "authenticate", return_value=(fake_ok, "test-user")), \
             patch("generate_artwork.generate_artwork", side_effect=RuntimeError("skip artwork in test")), \
             patch("sys.argv", ["export_to_spotify.py", "--stdin"]), \
             patch("sys.stdin", io.StringIO(json.dumps(tracks_in))), \
             patch("sys.stdout", out):
            export_to_spotify.main()

        stdout_text = out.getvalue()
        self.assertIn("AUDIT_LINE:Order audit: 2/2 verified in exact order (auto-repaired)", stdout_text)
        self.assertIn("SPOTIFY_URI:spotify:playlist:pl_1", stdout_text)
        self.assertEqual(fake_ok.playlists["pl_1"], ["spotify:track:A", "spotify:track:C"])

        # 2) Loud non-zero exit + no SPOTIFY_URI when audit fails even after repair
        fake_bad = _FakeSpotifyClient(search_map, corrupt_after_add=True, persist_corruption=True)
        out_bad = io.StringIO()
        with patch.object(export_to_spotify, "get_credentials", return_value=True), \
             patch.object(export_to_spotify, "authenticate", return_value=(fake_bad, "test-user")), \
             patch("sys.argv", ["export_to_spotify.py", "--stdin"]), \
             patch("sys.stdin", io.StringIO(json.dumps(tracks_in))), \
             patch("sys.stdout", out_bad):
            with self.assertRaises(SystemExit) as ctx:
                export_to_spotify.main()
        self.assertEqual(ctx.exception.code, 1)
        self.assertNotIn("SPOTIFY_URI:", out_bad.getvalue())


if __name__ == "__main__":
    unittest.main()
