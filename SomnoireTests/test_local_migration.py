import contextlib
import io
import pathlib
import plistlib
import runpy
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'scripts/migrate-local-preferences.py'
class LocalMigrationTests(unittest.TestCase):
    def test_allowlist_validation_preservation_and_alert_opt_in(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            base = root / 'Library/Containers'
            old = base / 'org.somnoire.Somnoire/Data/Library/Preferences/org.somnoire.Somnoire.plist'
            new = base / 'io.github.kusanalee.Somnoire/Data/Library/Preferences/io.github.kusanalee.Somnoire.plist'
            old.parent.mkdir(parents=True); new.parent.mkdir(parents=True)
            old.write_bytes(plistlib.dumps({'appMode':'fullReadings','monitoringEnabled':True,'appearance':'Dark','percentagePrecision':9,'selectedPeripheral':'malformed','lowBatteryAlerts':True,'unexpectedSecret':'excluded'}))
            new.write_bytes(plistlib.dumps({'appearance':'Light'}))
            original = old.read_bytes()
            with patch('pathlib.Path.home', return_value=root), contextlib.redirect_stdout(io.StringIO()):
                runpy.run_path(str(SCRIPT))
            result = plistlib.loads(new.read_bytes())
            self.assertEqual(result['appearance'], 'Light')
            self.assertEqual(result['appMode'], 'fullReadings')
            self.assertFalse(result['lowBatteryAlerts'])
            for key in ('selectedPeripheral','percentagePrecision','unexpectedSecret'):
                self.assertNotIn(key, result)
            self.assertEqual(old.read_bytes(), original)
            self.assertEqual(len(list((root/'Library/Application Support/Somnoire Migration').glob('*.plist'))), 1)
    def test_missing_old_preferences_leaves_new_data_alone(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            with patch('pathlib.Path.home', return_value=root), self.assertRaises(SystemExit):
                runpy.run_path(str(SCRIPT))
            self.assertFalse((root/'Library/Containers').exists())
