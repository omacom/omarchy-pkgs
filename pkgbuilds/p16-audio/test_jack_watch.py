import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader('watch', str(ROOT / 'jack-watch'))
spec = importlib.util.spec_from_loader('watch', loader)
watch = importlib.util.module_from_spec(spec)
loader.exec_module(watch)


class JackPolicyTests(unittest.TestCase):
    def test_recreated_sinks_restore_before_any_state_save(self):
        saved = {'volume': {'front-left': 8123, 'front-right': 9222},
                 'mute': True, 'dolby': False,
                 'dolby_volume': [16384, 16000], 'dolby_mute': True}
        original = [dict(index=10, name='p16_two_way'),
                    dict(index=11, name='p16_dolby_speakers')]
        known = {sink['name']: sink['index'] for sink in original}
        calls = []
        def run(*args, **kwargs):
            calls.append(args)
            return 'bluez_output.test' if args[:2] == ('pactl', 'get-default-sink') else ''
        with patch.object(watch, 'load_state', return_value=saved), \
                patch.object(watch, 'run', side_effect=run), \
                patch.object(watch, 'save_state') as save, \
                patch.object(watch, 'list_sinks', return_value=[]):
            watch.reconcile_speakers(known)
            save.assert_not_called()
        # New/change/server notifications may arrive with just one recreated sink.
        with patch.object(watch, 'load_state', return_value=saved), \
                patch.object(watch, 'run', side_effect=run), \
                patch.object(watch, 'save_state') as save:
            for sinks in ([dict(index=20, name='p16_two_way')],
                          [dict(index=20, name='p16_two_way'),
                           dict(index=21, name='p16_dolby_speakers')]):
                with patch.object(watch, 'list_sinks', return_value=sinks):
                    watch.reconcile_speakers(known)
            save.assert_not_called()
        self.assertIn(('pactl', 'set-sink-volume', '20', '8123', '9222'), calls)
        self.assertIn(('pactl', 'set-sink-mute', '20', '1'), calls)
        self.assertIn(('pactl', 'set-sink-volume', '21', '16384', '16000'), calls)
        self.assertIn(('pactl', 'set-sink-mute', '21', '1'), calls)
        self.assertFalse(any(c[:2] == ('pactl', 'set-default-sink') for c in calls))
        self.assertEqual(known, {'p16_two_way': 20, 'p16_dolby_speakers': 21})

    def test_normal_sink_changes_still_save_after_recovery(self):
        sinks = [dict(index=10, name='p16_two_way'),
                 dict(index=11, name='p16_dolby_speakers')]
        known = {s['name']: s['index'] for s in sinks}
        with patch.object(watch, 'list_sinks', return_value=sinks), \
                patch.object(watch, 'save_state') as save:
            watch.reconcile_speakers(known)
        save.assert_called_once()

    def test_filter_sinks_start_muted_before_policy_restoration(self):
        text = (ROOT / 'speakers.conf').read_text()
        import re
        for name in ('p16_two_way', 'p16_dolby_speakers'):
            block = re.search(r'capture.props\s*=\s*\{\s*node.name\s*=\s*"' + name + r'"(.*?)\n\s*\n?\s*\}', text, re.S)
            self.assertIsNotNone(block)
            self.assertIn('node.param.Props = { mute = true }', block[1])

    def transition(self, mode, default, saved):
        calls = []
        sinks = [{'name': 'p16_two_way', 'volume': {'front-left': {'value': 8192},
                  'front-right': {'value': 8192}}, 'mute': True}]
        def run(*args, check=True):
            calls.append(args)
            if args[:4] == ('pactl', '--format=json', 'list', 'sinks'):
                return json.dumps(sinks)
            if args[:2] == ('pactl', 'get-default-sink'):
                return default
            if args == ('pw-dump',):
                return '[]'
            return ''
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'state.json'
            state.write_text(json.dumps(saved))
            with patch.object(watch, 'STATE', state), patch.object(watch, 'run', side_effect=run), patch.object(watch, 'wait_sink'), patch.object(watch, 'set_alsa') as mixer:
                watch.switch(mode)
                result = json.loads(state.read_text())
        return calls, mixer, result

    def test_plug_preserves_speaker_volume_mute_and_mutes_all_speakers(self):
        calls, mixer, state = self.transition('headphones', 'p16_dolby_speakers', {'volume': {}, 'mute': False, 'dolby': True})
        self.assertEqual(state['volume'], {'front-left': 8192, 'front-right': 8192})
        self.assertTrue(state['mute'])
        self.assertTrue(state['dolby'])
        mixer.assert_any_call('cs42l43 Speaker Digital Switch', 'off,off')
        mixer.assert_any_call('AMP1 Speaker Switch', 'off')
        self.assertIn(('pactl', 'set-default-sink', 'p16_headphones'), calls)
        self.assertLess(calls.index(('pactl', 'set-sink-mute', 'p16_two_way', '1')), calls.index(('systemctl', '--user', 'start', 'p16-audio-host@headphones.service')))

    def test_unplug_restores_no_dolby_and_exact_saved_volume_and_mute(self):
        calls, _, _ = self.transition('speakers', 'p16_headphones', {'volume': {'front-left': 8123, 'front-right': 9222}, 'mute': True, 'dolby': False})
        self.assertIn(('pactl', 'set-default-sink', 'p16_two_way'), calls)
        self.assertIn(('pactl', 'set-sink-volume', 'p16_two_way', '8123', '9222'), calls)
        self.assertIn(('pactl', 'set-sink-mute', 'p16_two_way', '1'), calls)

    def test_bluetooth_default_survives_both_transitions(self):
        for mode in ('headphones', 'speakers'):
            calls, _, _ = self.transition(mode, 'bluez_output.test', {'volume': {}, 'mute': False, 'dolby': True})
            self.assertFalse(any(c[:2] == ('pactl', 'set-default-sink') for c in calls))

    def test_headphone_reader_uses_named_card(self):
        with patch.object(watch, 'run', return_value='values=on') as run:
            self.assertTrue(watch.jack_present())
        run.assert_called_once_with('amixer', '-c', 'mt8901soundwire', 'cget', watch.CONTROL)

    def test_dolby_volume_and_mute_restore_after_jack(self):
        calls, _, _ = self.transition('speakers', 'p16_headphones', {
            'volume': {'front-left': 65536, 'front-right': 65536},
            'mute': False, 'dolby': True,
            'dolby_volume': [16384, 16384], 'dolby_mute': True})
        self.assertIn(('pactl', 'set-sink-volume', 'p16_dolby_speakers', '16384', '16384'), calls)
        self.assertIn(('pactl', 'set-sink-mute', 'p16_dolby_speakers', '1'), calls)

    def test_boot_helper_never_unloads_driver(self):
        text = (ROOT / 'setup-route').read_text()
        self.assertNotIn('modprobe -r', text)
        self.assertNotIn('rmmod', text)


if __name__ == '__main__':
    unittest.main()
