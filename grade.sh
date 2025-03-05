#!/usr/bin/env bash

set -euo pipefail 

# Terminology
# - Aborting: Ending the program due to critical error
# - Skipping: Skipping a student due to student specific error

# TODO
# - Support comparing student output with expected output and saving as diff
# - Seperate test output and this program output 
# - Paralellize with GNU Parallel
# - Locale error: Student has name with unicode character :(

if command -v fd >/dev/null 2>&1; then
    FD_CMD="fd"
elif command -v fdfind >/dev/null 2>&1; then
    FD_CMD="fdfind"
else
    echo >&2 "Script requires 'fd' (or 'fdfind' on Debian-based systems) but neither is installed. Aborting."
    exit 1
fi

DEPENDENCIES=('firejail' 'zip')
for DEPENDENCY in "${DEPENDENCIES[@]}"; do
	if ! command -v "${DEPENDENCY}" > /dev/null 2>&1; then
		echo >&2 "Script requires '${DEPENDENCY}' but isn't installed. Aborting."
		exit 1
	fi
done


# Process arguments

INPUT_ZIPFILE="${1-}"
if [[ -z "${INPUT_ZIPFILE}" ]];
then
	echo "Usage: ${0} submissions_zipfile"
	exit 1
fi 

if [[ ! -f "${INPUT_ZIPFILE}" ]];
then 
	echo "Error: ${INPUT_ZIPFILE} does not exist"
	exit 1
fi

# Globals: All paths should be relative to this executable
ZIPPED="zipped/"
UNCLEAN_UNZIPPED="unclean_unzipped/"
CLEAN_UNZIPPED="clean_unzipped/"
RESULTS="results.csv"
TEST_CLASS="Test2.java" # Cannot have multiple periods. java -cp... depends on this!
TEST_CLASS_DEST="main/"
PROJECT_CLASSES=("main/PCB.java" "main/ProcessManager.java" "main/Queue.java")
EXPECTED_OUTPUT="expected.txt" # Not used
MOODLE_SUBMISSION_EXTENSION="_assignsubmission_file"

if [[ ! -f "${TEST_CLASS}" ]]; 
then
	echo "Error: Test Class does not exist at ${TEST_CLASS}."
	exit 1
fi

# Reset: Remove $ZIPPED, $UNZIPPED, and $RESULTS
rm -rf   "${ZIPPED}" "${UNCLEAN_UNZIPPED}" "${CLEAN_UNZIPPED}" "${RESULTS}"
mkdir -p "${ZIPPED}" "${UNCLEAN_UNZIPPED}" "${CLEAN_UNZIPPED}" "${RESULTS}"

# Unzip all moodle zipfile
unzip "${INPUT_ZIPFILE}" -d "${ZIPPED}" > /dev/null

# Process all submissions
mapfile -t student_submission_groups < <("${FD_CMD}" -I -t directory "${MOODLE_SUBMISSION_EXTENSION}$" "${ZIPPED}")

for student_submission_group in "${student_submission_groups[@]}"; do
	student_id="$(echo $(basename "${student_submission_group}") | cut -d'_' -f1)"
	echo "=== Running ${student_id}'s submission ==="

	# ============
	# Unzip submission and place in $UNCLEAN_UNZIPPED/$student_id
	# ============
	mapfile -t student_submissions < <("${FD_CMD}" -I -e 'zip' . "${student_submission_group}")
	if [[ "${#student_submissions[@]}" -gt 1 ]]; then
		echo "Multiple submissions found. Skipping..." 
		continue
	elif [[ "${#student_submissions[@]}" -lt 1 ]]; then
		echo "No submission found. Skipping..." 
		continue
	fi

	student_submission_zipped="${student_submissions[0]}"
	student_submission_unzipped_unclean="${UNCLEAN_UNZIPPED}${student_id}/"
	if ! unzip -q "${student_submission_zipped}" -d "${student_submission_unzipped_unclean}";
	then
		echo "Failed to unzip ${student_submission_zipped}"
		continue
	fi

	# ============
	# Submission Cleaning and Setup
	# ============
	# - Verify script contains all $PROJECT_CLASSES
	# - Move all project classes to $CLEAN_UNZIPPED/$student_id
	# - copy $TEST_CLASS to $CLEAN_UNZIPPED/$student_id/$TEST_CLASS_DEST/$TEST_CLASS
	ok=true
	student_submission_unzipped_clean="${CLEAN_UNZIPPED}${student_id}/"
	for PROJECT_CLASS in "${PROJECT_CLASSES[@]}"; do
		import_errors=()
		import_warnings=()
		compile_errors=()
		test_names=()
		tests_passed=()
		test_reasons=()
		for _ in "0"; do
			mapfile -t project_class_unclean_location < <("${FD_CMD}" -Ipt file "${PROJECT_CLASS}" "${student_submission_unzipped_unclean}")
			num_file_matches="${#project_class_unclean_location[@]}"
			if [[ "${num_file_matches}" -gt 1 ]];
			then
				echo "Too many files matching ${PROJECT_CLASS}. Skipping..."
				ok=false
				break
			elif [[ "${num_file_matches}" -lt 1 ]];
			then
				echo "No files matching ${PROJECT_CLASS}. Attempting coersion..."

				# Attempted coersion of file into correct package. If this fails not my problem
				# Changes package of a file matching basename ${PROJECT_CLASS} to expected package in-place
				mapfile -t project_class_unclean_location < <("${FD_CMD}" -Ipt file "$(basename "${PROJECT_CLASS}")" "${student_submission_unzipped_unclean}")
				num_file_matches="${#project_class_unclean_location[@]}"
				if [[ "${num_file_matches}" -gt 1 ]];
				then
					echo "Too many files matching $(basename ${PROJECT_CLASS}). Skipping..."
					ok=false
					break
				elif [[ "${num_file_matches}" -lt 1 ]];
				then
					echo "No files matching $(basename ${PROJECT_CLASS}). Skipping..."
					ok=false
					break
				fi
				to_coerce="${project_class_unclean_location[0]}"
				package="$(dirname "${PROJECT_CLASS}")"
				if sed -r 's/\s*package.*//' "${to_coerce}" | sed "1i package ${package};" > "${to_coerce}.tmp"; then
					mv "${to_coerce}.tmp" "${to_coerce}"
					echo "Successfully coerced"
				else
					echo "Failed to coerce"
					ok=false
					break
				fi
			fi 
			clean_dest="${student_submission_unzipped_clean}${PROJECT_CLASS}"
			mkdir -p "$(dirname "${clean_dest}")"
			if ! mv "${project_class_unclean_location[0]}" "${clean_dest}"; then
				echo "Failed to move ${project_class_unclean_location[0]} to ${clean_dest}. Skipping..."
				ok=false
				break
			fi
		done
		# Write results to csv
	done
	if ! $ok; then
		continue
	fi

	test_file_dest_dir="${student_submission_unzipped_clean}${TEST_CLASS_DEST}"
	mkdir -p "${test_file_dest_dir}"
	if ! cp "$(realpath "${TEST_CLASS}")" "${test_file_dest_dir}${TEST_CLASS}"; then
		echo "Failed to copy $(realpath ${TEST_CLASS}) to ${test_file_dest_dir}${TEST_CLASS}. Skipping..."
		continue
	fi

	# ============
	# Compile and Run Program Securely
	# ============
	# Writes results to a file named during runtime HAHA!
	if ! firejail \
		--noprofile \
		--read-only=/ \
		--private-cwd="$(realpath "${student_submission_unzipped_clean}")" \
		--whitelist="$(realpath "${student_submission_unzipped_clean}")" \
		javac "${TEST_CLASS_DEST}${TEST_CLASS}" "${PROJECT_CLASSES[@]}" 
	then
		echo "Failed to compile ${student_id}'s submission"
		continue
	fi
	results_dest="results_${RANDOM}.json"
	if ! firejail \
		--noprofile \
		--read-only=/ \
		--private-cwd="$(realpath "${student_submission_unzipped_clean}")" \
		--whitelist="$(realpath "${student_submission_unzipped_clean}")" \
		java -cp "$(realpath "${student_submission_unzipped_clean}")" "$(echo "${TEST_CLASS_DEST}${TEST_CLASS}" | cut -d'.' -f1)" -- "${results_dest}" > /dev/null
	then
		echo "Failed to run ${student_id}'s submission"
		continue
	fi
done

# Clean up
echo "Cleaning up..."
rm -rf "${ZIPPED}" "${UNCLEAN_UNZIPPED}" "${CLEAN_UNZIPPED}"
