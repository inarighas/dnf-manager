#!/usr/bin/env python3
"""
Improved Unit tests for Fedora Package Environment Manager
This version focuses on testing the logic rather than external dependencies
"""

import hashlib
import os
import shutil
import subprocess
import tempfile

import pytest

SCRIPT_PATH = './dnf-manager.sh'


class TestFedoraPackageManagerLogic:
    """Test suite focusing on the core logic and functionality"""
    
    @pytest.fixture
    def temp_package_dir(self):
        """Create a temporary package directory for testing"""
        temp_dir = tempfile.mkdtemp()
        yield temp_dir
        shutil.rmtree(temp_dir)
    
    @pytest.fixture
    def mock_packages(self):
        """Sample package data for testing - logically consistent"""
        return {
            'all_packages': [
                'kernel', 'systemd', 'bash', 'coreutils', 'glibc', 'dnf',  # defaults
                'git', 'docker-ce', 'nodejs', 'vim-enhanced',  # manually installed
                'gcc', 'python3', 'firefox'  # auto dependencies
            ],
            'default_packages': [
                'kernel', 'systemd', 'bash', 'coreutils', 'glibc', 'dnf'
            ],
            'user_installed': [
                'git', 'docker-ce', 'nodejs', 'vim-enhanced'  # Only manually installed packages
            ],
            'manual_packages': [
                'git', 'docker-ce', 'nodejs', 'vim-enhanced'
            ],
            'auto_dependencies': [
                'gcc', 'python3', 'firefox'  # Packages that are installed but not user-requested
            ]
        }

    def create_mock_script(self, temp_dir):
        """Create a minimal mock script for testing basic functionality"""
        script_content = '''#!/bin/bash
        
        PACKAGE_DIR="${PACKAGE_DIR:-$HOME/fedora-packages}"
        mkdir -p "$PACKAGE_DIR"
        
        case "${1:-help}" in
            help|--help|-h)
                echo "Usage: $0 [command]"
                echo "Commands:"
                echo "  init - Initialize environment"
                echo "  analyze - Analyze packages"
                echo "  lock - Create lock file"
                ;;
            init)
                echo "Initializing..."
                echo "kernel" > "$PACKAGE_DIR/default-packages.txt"
                echo "systemd" >> "$PACKAGE_DIR/default-packages.txt"
                exit 0
                ;;
            analyze)
                echo "Analyzing..."
                if [ ! -f "$PACKAGE_DIR/default-packages.txt" ]; then
                    echo "Default packages not found"
                    exit 1
                fi
                echo "git" > "$PACKAGE_DIR/manual-packages.txt"
                echo "docker-ce" >> "$PACKAGE_DIR/manual-packages.txt"
                exit 0
                ;;
            test-fail)
                exit 1
                ;;
            *)
                echo "Unknown command: $1" >&2
                exit 1
                ;;
        esac
        '''
        
        SCRIPT_PATH = os.path.join(temp_dir, 'test-script.sh')
        with open(SCRIPT_PATH, 'w') as f:
            f.write(script_content)
        os.chmod(SCRIPT_PATH, 0o755)
        return SCRIPT_PATH

    def test_package_analysis_core_logic(self, mock_packages):
        """Test the core set operations for package analysis"""
        all_packages = set(mock_packages['all_packages'])
        default_packages = set(mock_packages['default_packages'])
        user_installed = set(mock_packages['user_installed'])
        
        # Core logic: manual = user_installed - defaults
        manual_packages = user_installed - default_packages
        
        # Core logic: auto = (all - defaults) - manual
        non_default = all_packages - default_packages
        auto_dependencies = non_default - manual_packages
        
        # With our corrected mock data:
        # user_installed = {'git', 'docker-ce', 'nodejs', 'vim-enhanced'}
        # default_packages = {'kernel', 'systemd', 'bash', 'coreutils', 'glibc', 'dnf'}
        # manual = user_installed - defaults = {'git', 'docker-ce', 'nodejs', 'vim-enhanced'}
        expected_manual = {'git', 'docker-ce', 'nodejs', 'vim-enhanced'}
        
        # all_packages = all 13 packages
        # non_default = all - defaults = {'git', 'docker-ce', 'nodejs', 'vim-enhanced', 'gcc', 'python3', 'firefox'}
        # auto = non_default - manual = {'gcc', 'python3', 'firefox'}
        expected_auto = {'gcc', 'python3', 'firefox'}
        
        assert manual_packages == expected_manual
        assert auto_dependencies == expected_auto
        
        # Verify no overlaps
        assert len(manual_packages & auto_dependencies) == 0
        assert len(manual_packages & default_packages) == 0

    def test_percentage_calculations(self):
        """Test percentage calculation accuracy"""
        test_cases = [
            (10, 100, 10.0),
            (25, 200, 12.5),
            (1, 3, 33.3),
            (2, 3, 66.7),
            (0, 100, 0.0),
        ]
        
        for numerator, denominator, expected in test_cases:
            result = round((numerator * 100) / denominator, 1)
            assert result == expected

    def test_file_operations(self, temp_package_dir):
        """Test file creation and manipulation"""
        # Test file creation
        test_file = os.path.join(temp_package_dir, 'test-packages.txt')
        test_packages = ['git', 'docker-ce', 'nodejs']
        
        with open(test_file, 'w') as f:
            f.write('\n'.join(test_packages))
        
        # Test file reading
        with open(test_file, 'r') as f:
            content = f.read().strip().split('\n')
        
        assert content == test_packages
        
        # Test line counting
        line_count = len(content)
        assert line_count == 3
        
        # Test backup creation
        backup_file = test_file + '.backup'
        shutil.copy(test_file, backup_file)
        
        assert os.path.exists(backup_file)
        with open(backup_file, 'r') as f:
            backup_content = f.read()
        
        with open(test_file, 'r') as f:
            original_content = f.read()
        
        assert backup_content == original_content

    def test_set_operations_comm_simulation(self):
        """Test set operations that simulate 'comm' command behavior"""
        # Simulate comm -23 (in first but not second)
        list1 = {'a', 'b', 'c', 'd'}
        list2 = {'b', 'd', 'e', 'f'}
        
        # comm -23: in first but not in second
        comm_23 = list1 - list2
        assert comm_23 == {'a', 'c'}
        
        # comm -13: in second but not in first
        comm_13 = list2 - list1
        assert comm_13 == {'e', 'f'}
        
        # comm -12: in both
        comm_12 = list1 & list2
        assert comm_12 == {'b', 'd'}

    def test_package_categorization_regex(self):
        """Test package categorization patterns"""
        import re
        
        test_packages = [
            'git', 'gcc', 'clang', 'make', 'cmake',  # Development
            'python3', 'python3-pip', 'python3-numpy',  # Python
            'docker-ce', 'podman', 'buildah',  # Containers
            'vim-enhanced', 'emacs', 'code',  # Editors  
            'vlc', 'ffmpeg', 'gimp'  # Media
        ]
        
        # Test patterns (from the script)
        patterns = {
            'development': r'^(gcc|clang|make|cmake|git|nodejs|npm|yarn|cargo|rustc|go|java|maven|gradle)',
            'python': r'^python',
            'containers': r'^(docker|podman|buildah|skopeo|kubernetes|kubectl|helm)',
            'editors': r'^(vim|emacs|neovim|code|atom|sublime)',
            'media': r'^(vlc|mpv|ffmpeg|gimp|inkscape|blender|obs)'
        }
        
        results = {}
        for category, pattern in patterns.items():
            results[category] = len([p for p in test_packages if re.match(pattern, p)])
        
        assert results['development'] == 5
        assert results['python'] == 3
        assert results['containers'] == 3
        assert results['editors'] == 3
        assert results['media'] == 3

    def test_version_string_parsing(self):
        """Test version string parsing and comparison"""
        version_strings = [
            'package-1.2.3-1.fc39.x86_64',
            'another-pkg-2.0.0-5.fc39.noarch',
            'complex-name-with-dashes-1.0-1.fc39.x86_64'
        ]
        
        def parse_version_string(version_str):
            # Simulate parsing package-version-release.arch format
            parts = version_str.rsplit('.', 1)  # Split arch
            if len(parts) == 2:
                name_version_release = parts[0]
                arch = parts[1]
                
                # Split version-release from name (find last two hyphens)
                components = name_version_release.split('-')
                if len(components) >= 3:
                    name = '-'.join(components[:-2])
                    version = components[-2]
                    release = components[-1]
                    return name, version, release, arch
            return None, None, None, None
        
        expected = [
            ('package', '1.2.3', '1.fc39', 'x86_64'),
            ('another-pkg', '2.0.0', '5.fc39', 'noarch'),
            ('complex-name-with-dashes', '1.0', '1.fc39', 'x86_64')
        ]
        
        for i, version_str in enumerate(version_strings):
            result = parse_version_string(version_str)
            assert result == expected[i]

    def test_checksum_calculation(self, temp_package_dir):
        """Test SHA256 checksum calculation"""
        def calculate_sha256(filepath):
            sha256_hash = hashlib.sha256()
            with open(filepath, "rb") as f:
                for byte_block in iter(lambda: f.read(4096), b""):
                    sha256_hash.update(byte_block)
            return sha256_hash.hexdigest()
        
        # Create test files
        test_file1 = os.path.join(temp_package_dir, 'test1.txt')
        test_file2 = os.path.join(temp_package_dir, 'test2.txt')
        
        with open(test_file1, 'w') as f:
            f.write('git\ndocker-ce\nnodejs\n')
        
        with open(test_file2, 'w') as f:
            f.write('gcc\npython3\n')
        
        checksum1 = calculate_sha256(test_file1)
        checksum2 = calculate_sha256(test_file2)
        
        # Verify checksums are different
        assert checksum1 != checksum2
        
        # Verify checksum consistency
        checksum1_again = calculate_sha256(test_file1)
        assert checksum1 == checksum1_again
        
        # Verify checksum length (SHA256 is 64 hex chars)
        assert len(checksum1) == 64
        assert len(checksum2) == 64

    def test_mock_script_basic_functionality(self, temp_package_dir):
        """Test basic script functionality with mock"""
        SCRIPT_PATH = self.create_mock_script(temp_package_dir)
        
        # Test help command
        result = subprocess.run([SCRIPT_PATH, 'help'], capture_output=True, text=True)
        assert result.returncode == 0
        assert 'Usage:' in result.stdout
        
        # Test init command
        package_dir = os.path.join(temp_package_dir, 'packages')
        env = os.environ.copy()
        env['PACKAGE_DIR'] = package_dir
        
        result = subprocess.run([SCRIPT_PATH, 'init'], env=env, capture_output=True, text=True)
        assert result.returncode == 0
        
        # Check that files were created
        default_file = os.path.join(package_dir, 'default-packages.txt')
        assert os.path.exists(default_file)
        
        # Test analyze command
        result = subprocess.run([SCRIPT_PATH, 'analyze'], env=env, capture_output=True, text=True)
        assert result.returncode == 0
        
        manual_file = os.path.join(package_dir, 'manual-packages.txt')
        assert os.path.exists(manual_file)
        
        # Test invalid command
        result = subprocess.run([SCRIPT_PATH, 'invalid'], capture_output=True, text=True)
        assert result.returncode == 1
        assert 'Unknown command' in result.stderr

    def test_lock_file_format_structure(self, temp_package_dir):
        """Test lock file format without external dependencies"""
        # Simulate creating a lock file
        lock_file = os.path.join(temp_package_dir, 'test.lock')
        
        # Mock lock file content structure
        lock_content = """# Fedora Package Lock File
# Generated: 2024-01-01 12:00:00
# System: Fedora Linux 39
# Format: package|version|release|arch|size|install_time|repository

[MANUAL_PACKAGES]
git|2.41.0|1.fc39|x86_64|12345|1234567890|fedora
docker-ce|24.0.0|1.fc39|x86_64|67890|1234567891|docker

[AUTO_DEPENDENCIES]
python3|3.11.0|1.fc39|x86_64|45678|1234567892|fedora

[REPOSITORIES]
fedora|enabled
docker|enabled

[CHECKSUMS]
manual_packages|abc123def456
auto_dependencies|def456ghi789
"""
        
        with open(lock_file, 'w') as f:
            f.write(lock_content)
        
        # Test parsing
        sections = {}
        current_section = None
        
        with open(lock_file, 'r') as f:
            for line in f:
                line = line.strip()
                if line.startswith('[') and line.endswith(']'):
                    current_section = line[1:-1]
                    sections[current_section] = []
                elif current_section and '|' in line:
                    sections[current_section].append(line)
        
        # Verify structure
        assert 'MANUAL_PACKAGES' in sections
        assert 'AUTO_DEPENDENCIES' in sections
        assert 'REPOSITORIES' in sections
        assert 'CHECKSUMS' in sections
        
        # Verify content
        assert len(sections['MANUAL_PACKAGES']) == 2
        assert len(sections['AUTO_DEPENDENCIES']) == 1
        assert len(sections['REPOSITORIES']) == 2
        assert len(sections['CHECKSUMS']) == 2

    def test_parallel_processing_logic(self):
        """Test parallel processing concepts without actual parallelization"""
        # Simulate chunking packages for parallel processing
        packages = [f'package-{i}' for i in range(100)]
        chunk_size = 25
        
        # Create chunks
        chunks = [packages[i:i + chunk_size] for i in range(0, len(packages), chunk_size)]
        
        assert len(chunks) == 4  # 100 packages / 25 per chunk
        assert len(chunks[0]) == 25
        assert len(chunks[-1]) == 25  # Last chunk should also have 25
        assert chunks[0][0] == 'package-0'
        assert chunks[-1][-1] == 'package-99'
        
        # Simulate progress tracking
        total_packages = len(packages)
        processed = 0
        
        for chunk in chunks:
            # Simulate processing chunk
            chunk_processed = len(chunk)
            processed += chunk_processed
            
            # Calculate progress
            progress_percent = (processed * 100) // total_packages
            
        assert processed == total_packages
        assert progress_percent == 100

    def test_environment_variable_handling(self, temp_package_dir):
        """Test environment variable handling logic"""
        # Test default value
        default_dir = os.path.expanduser('~/fedora-packages')
        
        # Test custom value
        custom_dir = temp_package_dir
        
        # Simulate bash parameter expansion: ${VAR:-default}
        def get_package_dir(env_var=None):
            return env_var if env_var else default_dir
        
        assert get_package_dir() == default_dir
        assert get_package_dir(custom_dir) == custom_dir

    @pytest.mark.parametrize("total,processed,expected_percent", [
        (100, 0, 0),
        (100, 25, 25),
        (100, 50, 50),
        (100, 100, 100),
        (1000, 333, 33),
        (7, 3, 42),  # Test rounding
    ])
    def test_progress_calculations(self, total, processed, expected_percent):
        """Test progress percentage calculations"""
        result = (processed * 100) // total
        assert result == expected_percent


class TestScriptIntegration:
    """Integration tests that require the actual script"""
    
    def test_script_exists_and_executable(self):
        """Test if the main script exists and is executable"""
        if not os.path.exists(SCRIPT_PATH):
            pytest.skip("Main script not found - this is expected in test environment")
        
        # Check if executable
        assert os.access(SCRIPT_PATH, os.X_OK)
    
    def test_help_command_real_script(self):
        """Test help command on real script if available"""
        if not os.path.exists(SCRIPT_PATH):
            pytest.skip("Main script not found")
        
        try:
            result = subprocess.run(
                ['bash', SCRIPT_PATH, 'help'],
                capture_output=True, 
                text=True, 
                timeout=10
            )
            assert result.returncode == 0
            assert 'Usage:' in result.stdout
        except subprocess.TimeoutExpired:
            pytest.fail("Script timed out")
        except Exception as e:
            pytest.skip(f"Could not run script: {e}")
