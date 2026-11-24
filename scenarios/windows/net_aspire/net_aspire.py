# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

##
# .NET Apire Compiling Workload
##

import logging
import os
import core.app_scenario
from core.parameters import Params
from datetime import datetime

class NetAspire(core.app_scenario.Scenario):

    module = __module__.split('.')[-1]
    prep_version = "10"
    resources = module + "_resources"


    # Set default parameters
    Params.setDefault(module, 'loops', '4')
    Params.setDefault(module, 'binlog', '0', desc="Collect an MSBuild binary log for each build (adds overhead).", valOptions=['0', '1'])
    Params.setDefault(module, 'skip_playwright_browser_install', '0', desc="Skip Playwright browser installation during the timed build.", valOptions=['0', '1'])
    Params.setDefault(module, 'max_cpu_count', '0', desc="Maximum concurrent MSBuild processes (0 keeps the original default; experiment B: 12).")
    Params.setDefault(module, 'direct_schema_exec', '0', desc="Launch the Aspire SchemaGenerator directly without a command shell.", valOptions=['0', '1'])
    Params.setDefault(module, 'schema_timing', '0', desc="Collect SchemaGenerator phase timings (requires direct_schema_exec=1 and binlog=0).", valOptions=['0', '1'])
    Params.setDefault(module, 'schema_runtime', 'default', desc="SchemaGenerator runtime for diagnostics; 11 selects an installed .NET 11 runtime.", valOptions=['default', '11'])


    def setUp(self):
        # Get parameters
        self.platform = Params.get('global', 'platform')
        self.loops = Params.get(self.module, 'loops')
        self.binlog = Params.get(self.module, 'binlog') == '1'
        self.skip_playwright_browser_install = Params.get(self.module, 'skip_playwright_browser_install') == '1'
        self.direct_schema_exec = Params.get(self.module, 'direct_schema_exec') == '1'
        self.schema_timing = Params.get(self.module, 'schema_timing') == '1'
        self.schema_runtime = Params.get(self.module, 'schema_runtime')
        if self.schema_runtime not in ('default', '11'):
            raise ValueError("schema_runtime must be default or 11.")
        if self.schema_runtime != 'default' and not self.schema_timing:
            raise ValueError("schema_runtime=11 requires schema_timing=1.")
        if self.schema_timing and (not self.direct_schema_exec or self.binlog):
            raise ValueError("schema_timing requires direct_schema_exec=1 and binlog=0.")
        try:
            self.max_cpu_count = int(Params.get(self.module, 'max_cpu_count'))
        except (TypeError, ValueError):
            raise ValueError("max_cpu_count must be a non-negative 32-bit integer (0 keeps the original default).") from None
        if not 0 <= self.max_cpu_count <= 2147483647:
            raise ValueError("max_cpu_count must be a non-negative 32-bit integer (0 keeps the original default).")

        self.target = f"{self.dut_exec_path}\\{self.resources}"

        # Test if already set up
        if self.checkPrepStatus([self.module + self.prep_version]):
            logging.info("Preparing for first use.")

            # Copy over resources to DUT
            logging.info(f"Uploading test files to {self.target}")
            self._upload(f"scenarios\\windows\\{self.module}\\{self.resources}", self.dut_exec_path)

            # Excute prep script
            logging.info("Executing prep, this make take 10-15 minutes...")
            try:
                self._call(["pwsh", f"{self.target}\\{self.module}_prep.ps1"])
            finally:
                self._copy_data_from_remote(self.result_dir)
            self.createPrepStatusControlFile(self.prep_version)
        else:
            resources_dir = f"scenarios\\windows\\{self.module}\\{self.resources}"
            if self.binlog or self.skip_playwright_browser_install or self.max_cpu_count or self.direct_schema_exec:
                self._upload(f"{resources_dir}\\{self.module}_run.ps1", self.target, check_modified=False)
            if self.direct_schema_exec:
                self._upload(f"{resources_dir}\\DirectSchemaExec.targets", self.target, check_modified=False)
            if self.schema_timing:
                self._upload(f"{resources_dir}\\SchemaTiming.ps1", self.target, check_modified=False)

        # Call base class setUp() to dump config, call tool callbacks, and start measurment
        core.app_scenario.Scenario.setUp(self)


    def runTest(self):
        start_time = datetime.now().astimezone().isoformat()
        run_args = " -binlog" if self.binlog else ""
        if self.skip_playwright_browser_install:
            run_args += " -skipPlaywrightBrowserInstall"
        if self.max_cpu_count:
            run_args += f" -maxCpuCount {self.max_cpu_count}"
        if self.direct_schema_exec:
            run_args += " -directSchemaExec"
        if self.schema_timing:
            run_args += " -schemaTiming"
        if self.schema_runtime == '11':
            run_args += " -schemaRuntime 11"
        for i in range(int(self.loops)):
            logging.info(f"Running loop {i + 1}")
            self._call(["pwsh", f"{self.target}\\{self.module}_run.ps1 -startTime {start_time}{run_args}"])


    def tearDown(self):
        logging.info("Performing teardown.")
        # Call base class tearDown() to stop measurment, copy back data from DUT, and call tool callbacks
        core.app_scenario.Scenario.tearDown(self)

        logging.info("Executing teardown script.")
        self._call(["pwsh", f"{self.target}\\{self.module}_teardown.ps1"])


    def kill(self):
        try:
            logging.debug("Killing command shell")
            self._kill("cmd.exe")
        except:
            pass

