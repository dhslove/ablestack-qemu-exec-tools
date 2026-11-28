#!/usr/bin/env python3
# Copyright 2026 ABLECLOUD. Licensed under the Apache License, Version 2.0.
"""Do not certify an initramfs that cannot supply the planned storage drivers."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

path=Path(__file__).resolve().parents[1]/'lib/v2k/guest-config/prepare-linux-drivers.py'
spec=importlib.util.spec_from_file_location('linux_driver_preparation',path)
drivers=importlib.util.module_from_spec(spec);spec.loader.exec_module(drivers)


class DriverQualification(unittest.TestCase):
    def test_builtin_kmod_header_does_not_require_a_nonexistent_payload(self):
        with patch.object(drivers,'run',return_value='name: virtio_pci\n(builtin)\n'):
            drivers.verify_modules('kernel','')

    def test_actual_kernel_filename_resolves_hyphen_aliases(self):
        def modinfo(*args):return '/lib/modules/kernel/'+args[-1].replace('_','-')+'.ko.xz\n'
        listing='\n'.join(m.replace('_','-')+'.ko' for m in drivers.MODULES)
        with patch.object(drivers,'run',side_effect=modinfo):drivers.verify_modules('kernel',listing)

    def test_missing_ahci_cannot_receive_verified_evidence(self):
        with patch.object(drivers,'run',return_value='/lib/modules/kernel/ahci.ko.xz\n'):
            with self.assertRaisesRegex(ValueError,'MODULE_MISSING: ahci'):drivers.verify_modules('kernel','')

    def test_unknown_module_is_a_hard_failure(self):
        with patch.object(drivers,'run',side_effect=RuntimeError('modinfo failed')):
            with self.assertRaises(RuntimeError):drivers.verify_modules('kernel','')


    def test_minimal_rocky_without_lvm_only_adds_planned_storage_drivers(self):
        with patch.object(drivers.Path, 'is_file', return_value=True), \
             patch.object(drivers.shutil, 'which', return_value=None), \
             patch.object(drivers, 'run', side_effect=['base\n', '', 'archive']) as run:
            self.assertEqual('archive', drivers.prepare_rocky_initramfs('kernel', 'image'))
        self.assertNotIn('lvm', run.call_args_list[1].args)
        self.assertIn(' '.join(drivers.MODULES), run.call_args_list[1].args)

    def test_rocky_preserves_and_checks_lvm_from_the_source_initramfs(self):
        with patch.object(drivers.Path, 'is_file', return_value=True), \
             patch.object(drivers.shutil, 'which', return_value=None), \
             patch.object(drivers, 'run', side_effect=['base\nlvm\n', '', 'base\n']) as run:
            with self.assertRaisesRegex(ValueError, 'INITRAMFS_LVM_MISSING'):
                drivers.prepare_rocky_initramfs('kernel', 'image')
        self.assertIn('lvm', run.call_args_list[1].args)


if __name__=='__main__':unittest.main(verbosity=2)
