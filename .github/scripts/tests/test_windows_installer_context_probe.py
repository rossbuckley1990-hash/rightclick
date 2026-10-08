#!/usr/bin/env python3
"""Synthetic privacy/deadline controls; no fake native installer proof."""
from pathlib import Path
import json,os,sys,unittest
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'.github/scripts'))
import windows_installer_context_probe as p
CONTROL_ENV={'SystemRoot':os.environ.get('SystemRoot',r'C:\Windows')} if os.name=='nt' else {}

class ContextProbeTests(unittest.TestCase):
    def test_minimum_and_explicit_context_exclude_bearer_and_path(self):
        ambient={'SYSTEMROOT':r'C:\Windows','ProgramData':r'C:\ProgramData',
                 'ALLUSERSPROFILE':r'C:\ProgramData','ProgramFiles':r'C:\Program Files',
                 'ProgramFiles(x86)':r'C:\Program Files (x86)',
                 'PATH':'private-control-sentinel','TOKEN':'private-control-sentinel',
                 'USERPROFILE':'private-control-sentinel'}
        minimal,context,presence=p.profiles(ambient,r'C:\OwnedTemporary')
        self.assertEqual(set(minimal),{'SystemRoot','TEMP','TMP'})
        self.assertEqual(set(context)-set(minimal),set(p.CONTEXT_NAMES))
        self.assertNotIn('private-control-sentinel',json.dumps([minimal,context,presence]))
        self.assertEqual(set(presence.values()),{True})

    def test_missing_context_is_observed_without_inventing_values(self):
        minimal,context,presence=p.profiles({},r'C:\OwnedTemporary')
        self.assertEqual(minimal,context)
        self.assertEqual(set(presence.values()),{False})

    def test_invalid_or_redirectable_context_values_are_rejected(self):
        for value in ['relative',r'\\remote\share',r'C:relative','C:\\quoted"path',
                      'C:\\private\npath','C:\\private\x00path','C:\\'+'a'*4097]:
            with self.assertRaises(ValueError): p.host_path(value)
        with self.assertRaises(ValueError):
            p.profiles({'ProgramData':r'C:\One','PROGRAMDATA':r'C:\Two'},r'C:\OwnedTemporary')

    def test_context_total_budget_is_enforced(self):
        with self.assertRaises(ValueError):
            p.profiles({name:'C:\\'+'a'*3000 for name in p.CONTEXT_NAMES},r'C:\OwnedTemporary')

    def test_output_projection_contains_flags_not_the_private_selection(self):
        value=r'C:\Private Control Sentinel\Installed Compiler'.encode()
        projected=p.validation(value)
        self.assertTrue(projected['isAbsolute'])
        self.assertFalse(projected['empty'])
        self.assertNotIn('Private Control Sentinel',json.dumps(projected))
        self.assertTrue(p.validation(b'\xef\xbb\xbfC:\\Compiler')['startsUTF8BOM'])

    def test_natural_child_failure_is_retained_without_error_text(self):
        result=p.sample(Path(sys.executable),['-c','raise SystemExit(7)'],CONTROL_ENV,deadline=2)
        self.assertEqual((result['outcome'],result['exitCode']),('child_failed',7))
        self.assertTrue(result['outputDrainCompleted'])

    def test_silent_child_is_killed_at_owned_deadline(self):
        result=p.sample(Path(sys.executable),['-c','import time; time.sleep(5)'],CONTROL_ENV,deadline=0.1)
        self.assertEqual(result['outcome'],'deadline')
        self.assertLess(result['elapsedMilliseconds'],2000)
        self.assertTrue(result['outputDrainCompleted'])

    def test_stdout_budget_does_not_retain_or_print_unbounded_payload(self):
        result=p.sample(Path(sys.executable),['-c',"import os; os.write(1,b'private-control-sentinel'*10000)"],CONTROL_ENV,deadline=2,maximum=64)
        self.assertEqual(result['outcome'],'output_budget')
        self.assertLessEqual(result['retainedBytes'],64)
        self.assertNotIn('private-control-sentinel',json.dumps(result))

    def test_large_stderr_is_discarded_and_only_stdout_scalars_are_reported(self):
        result=p.sample(Path(sys.executable),['-c',"import os; os.write(2,b'private-control-sentinel'*100000); os.write(1,b'owned')"],CONTROL_ENV,deadline=2)
        self.assertEqual((result['outcome'],result['exitCode'],result['stdoutBytes']),('completed',0,5))
        self.assertNotIn('private-control-sentinel',json.dumps(result))

    def test_same_query_arguments_are_closed_and_workflow_owns_probe(self):
        self.assertEqual(p.ARGUMENTS,['-latest','-products','*','-requires',
            'Microsoft.VisualStudio.Component.VC.Tools.x86.x64','-property','installationPath'])
        workflow=(ROOT/'.github/workflows/windows-installer-context-ab-probe.yml').read_text()
        self.assertIn('--deadline-seconds 45 --progress -- python -u .github/scripts/windows_installer_context_probe.py',workflow)
        self.assertIn('installer-context-safe/installer-context.json',workflow)
        self.assertNotIn('installer-context-safe/**',workflow)

if __name__=='__main__': unittest.main(verbosity=2)
