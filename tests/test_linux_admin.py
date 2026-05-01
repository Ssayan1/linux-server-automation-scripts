#!/usr/bin/env python3
"""
test_linux_admin.py — Unit Tests for linux_admin.py
Run: python3 -m pytest tests/ -v
 OR: python3 tests/test_linux_admin.py
"""

import collections
import os
import sys
import tempfile
import unittest

# ── Add parent directory to path so we can import linux_admin ─────────────────
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import linux_admin


# ═══════════════════════════════════════════════════════════════════════════════
#  LOG ANALYSIS TESTS
# ═══════════════════════════════════════════════════════════════════════════════

class TestLogAnalysis(unittest.TestCase):

    def setUp(self):
        """Create a temporary log file for each test."""
        self.log_file = tempfile.NamedTemporaryFile(
            mode='w', suffix='.log', delete=False
        )
        self.log_file.write(
            "2026-05-01 10:00:01 INFO  Server started\n"
            "2026-05-01 10:01:00 WARNING Disk usage high: 85%\n"
            "2026-05-01 10:02:00 ERROR Connection refused: 127.0.0.1:3306\n"
            "2026-05-01 10:03:00 ERROR Failed password for admin\n"
            "2026-05-01 10:04:00 DEBUG Cache miss for key: abc123\n"
            "2026-05-01 10:05:00 CRITICAL Out of memory: Kill process 1821\n"
            "2026-05-01 10:06:00 INFO  Request processed: GET /api 200\n"
            "2026-05-01 10:07:00 WARNING High memory usage: 92%\n"
            "2026-05-01 10:08:00 ERROR SSL certificate expires in 3 days\n"
        )
        self.log_file.close()

    def tearDown(self):
        """Remove temp file after each test."""
        os.unlink(self.log_file.name)

    def _count_levels(self, lines):
        """Helper — count log levels in a list of lines."""
        counts = collections.Counter()
        for _, line in lines:
            for lvl, pat in linux_admin.LOG_PATTERNS.items():
                if pat.search(line):
                    counts[lvl] += 1
        return counts

    def test_log_file_exists(self):
        """Log file should exist and be readable."""
        self.assertTrue(os.path.exists(self.log_file.name))

    def test_error_count(self):
        """Should detect 4 ERROR lines (ERROR x3 + CRITICAL x1)."""
        with open(self.log_file.name) as f:
            lines = f.readlines()
        matched = [
            (i, l.rstrip()) for i, l in enumerate(lines, 1)
            if linux_admin.LOG_PATTERNS["ERROR"].search(l)
        ]
        self.assertEqual(len(matched), 4)

    def test_warning_count(self):
        """Should detect 2 WARNING lines."""
        with open(self.log_file.name) as f:
            lines = f.readlines()
        matched = [
            (i, l.rstrip()) for i, l in enumerate(lines, 1)
            if linux_admin.LOG_PATTERNS["WARNING"].search(l)
        ]
        self.assertEqual(len(matched), 2)

    def test_info_count(self):
        """Should detect 2 INFO lines."""
        with open(self.log_file.name) as f:
            lines = f.readlines()
        matched = [
            (i, l.rstrip()) for i, l in enumerate(lines, 1)
            if linux_admin.LOG_PATTERNS["INFO"].search(l)
        ]
        self.assertEqual(len(matched), 2)

    def test_debug_count(self):
        """Should detect 1 DEBUG line."""
        with open(self.log_file.name) as f:
            lines = f.readlines()
        matched = [
            (i, l.rstrip()) for i, l in enumerate(lines, 1)
            if linux_admin.LOG_PATTERNS["DEBUG"].search(l)
        ]
        self.assertEqual(len(matched), 1)

    def test_total_line_count(self):
        """Log file should have exactly 9 lines."""
        with open(self.log_file.name) as f:
            lines = f.readlines()
        self.assertEqual(len(lines), 9)

    def test_tail_option(self):
        """Tail should limit lines read."""
        with open(self.log_file.name) as f:
            all_lines = f.readlines()
        tail_lines = all_lines[-3:]
        self.assertEqual(len(tail_lines), 3)

    def test_error_detail_extraction(self):
        """Should extract error message details correctly."""
        test_line = "2026-05-01 ERROR Connection refused: 127.0.0.1:3306"
        match = linux_admin.ERROR_DETAIL.search(test_line)
        self.assertIsNotNone(match)
        self.assertIn("Connection refused", match.group(1))

    def test_report_file_created(self):
        """Report file should be created when path is provided."""
        with tempfile.NamedTemporaryFile(
            mode='w', suffix='.txt', delete=False
        ) as report_file:
            report_path = report_file.name

        # Simulate what analyze_log writes
        with open(report_path, 'w') as rf:
            rf.write("Log Analysis Report\n")
            rf.write("Generated: 2026-05-01\n")

        self.assertTrue(os.path.exists(report_path))
        with open(report_path) as rf:
            content = rf.read()
        self.assertIn("Log Analysis Report", content)
        os.unlink(report_path)

    def test_empty_log_file(self):
        """Should handle empty log files gracefully."""
        empty_log = tempfile.NamedTemporaryFile(
            mode='w', suffix='.log', delete=False
        )
        empty_log.close()
        with open(empty_log.name) as f:
            lines = f.readlines()
        self.assertEqual(len(lines), 0)
        os.unlink(empty_log.name)

    def test_pattern_case_insensitive(self):
        """Log patterns should match regardless of case."""
        test_lines = [
            "error something failed",
            "ERROR something failed",
            "Error something failed",
        ]
        for line in test_lines:
            self.assertIsNotNone(
                linux_admin.LOG_PATTERNS["ERROR"].search(line),
                f"Pattern should match: {line}"
            )


# ═══════════════════════════════════════════════════════════════════════════════
#  LOG PATTERN TESTS
# ═══════════════════════════════════════════════════════════════════════════════

class TestLogPatterns(unittest.TestCase):

    def test_all_patterns_exist(self):
        """All required log level patterns should be defined."""
        required = ["ERROR", "WARNING", "INFO", "DEBUG"]
        for level in required:
            self.assertIn(level, linux_admin.LOG_PATTERNS)

    def test_critical_matches_error_pattern(self):
        """CRITICAL keyword should match ERROR pattern."""
        line = "2026-05-01 CRITICAL system failure"
        self.assertIsNotNone(linux_admin.LOG_PATTERNS["ERROR"].search(line))

    def test_fatal_matches_error_pattern(self):
        """FATAL keyword should match ERROR pattern."""
        line = "2026-05-01 FATAL disk full"
        self.assertIsNotNone(linux_admin.LOG_PATTERNS["ERROR"].search(line))

    def test_warn_matches_warning_pattern(self):
        """WARN keyword should match WARNING pattern."""
        line = "2026-05-01 WARN memory high"
        self.assertIsNotNone(linux_admin.LOG_PATTERNS["WARNING"].search(line))

    def test_notice_matches_info_pattern(self):
        """NOTICE keyword should match INFO pattern."""
        line = "2026-05-01 NOTICE server restarted"
        self.assertIsNotNone(linux_admin.LOG_PATTERNS["INFO"].search(line))

    def test_no_false_positives(self):
        """Normal lines should not match ERROR pattern."""
        normal_lines = [
            "2026-05-01 INFO  Server started successfully",
            "2026-05-01 DEBUG Processing request",
            "Request completed in 120ms",
        ]
        for line in normal_lines:
            self.assertIsNone(
                linux_admin.LOG_PATTERNS["ERROR"].search(line),
                f"Should NOT match ERROR: {line}"
            )


# ═══════════════════════════════════════════════════════════════════════════════
#  USER/GROUP HELPER TESTS
# ═══════════════════════════════════════════════════════════════════════════════

class TestUserHelpers(unittest.TestCase):

    def test_root_user_exists(self):
        """Root user should always exist on Linux."""
        self.assertTrue(linux_admin.user_exists("root"))

    def test_nonexistent_user(self):
        """Nonexistent user should return False."""
        self.assertFalse(linux_admin.user_exists("thisuserdoesnotexist99999"))

    def test_root_group_exists(self):
        """Root group should always exist on Linux."""
        self.assertTrue(linux_admin.group_exists("root"))

    def test_nonexistent_group(self):
        """Nonexistent group should return False."""
        self.assertFalse(linux_admin.group_exists("thisgroupdoesnotexist99999"))

    def test_current_user_exists(self):
        """Current logged-in user should exist."""
        import pwd
        current = pwd.getpwuid(os.getuid()).pw_name
        self.assertTrue(linux_admin.user_exists(current))


# ═══════════════════════════════════════════════════════════════════════════════
#  RUNNER
# ═══════════════════════════════════════════════════════════════════════════════

if __name__ == "__main__":
    print("\n🧪 Running Linux Admin Unit Tests\n" + "="*50)
    loader   = unittest.TestLoader()
    suite    = unittest.TestSuite()

    suite.addTests(loader.loadTestsFromTestCase(TestLogAnalysis))
    suite.addTests(loader.loadTestsFromTestCase(TestLogPatterns))
    suite.addTests(loader.loadTestsFromTestCase(TestUserHelpers))

    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    total  = result.testsRun
    passed = total - len(result.failures) - len(result.errors)
    print(f"\n{'='*50}")
    print(f"✅ Passed : {passed}/{total}")
    if result.failures or result.errors:
        print(f"❌ Failed : {len(result.failures) + len(result.errors)}")
        sys.exit(1)
    else:
        print("🎉 All tests passed!")
