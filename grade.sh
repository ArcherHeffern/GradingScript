#!/usr/bin/env bash

set -euo pipefail 

# TODO
# - Support comparing student output with expected output and saving as diff
# - Cd doesn't check for errors
# - Verify the test script is ran and student doesn't override it 


command -v fd >/dev/null 2>&1 || { echo >&2 "Script requires 'fd' but it's not installed.  Aborting."; exit 1; }

# Process arguments

INPUT_ZIPFILE="${1-}"
if [[ -z "${INPUT_ZIPFILE}" ]];
then
	echo "Usage: ${0} submissions_zipfile dest_dir"
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
RESULTS="results/"
TEST_CLASS="Test.java"
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

# Post processing of variables - Don't touch!
RESULTS="$(realpath "${RESULTS}")/"
if [[ $? -ne 0 ]]; then
	echo "Failed to find realpath of ${RESULTS}"
fi
TEST_CLASS_ABS_PATH="$(realpath "${TEST_CLASS}")"
if [[ $? -ne 0 ]]; then
	echo "Failed to find realpath of ${TEST_CLASS}"
fi

# Unzip all moodle zipfile
unzip "${INPUT_ZIPFILE}" -d "${ZIPPED}" > /dev/null

# Process all submissions
mapfile -t student_submissions_zipped < <(fd --full-path -I -e=zip "${MOODLE_SUBMISSION_EXTENSION}" "${ZIPPED}")

for student_submission_zipped in "${student_submissions_zipped[@]}"; do
	student_id="$(basename "${student_submission_zipped::-4}")"
	echo "=== Running ${student_id}'s submission ==="

	# ============
	# Unzip submission and place in $UNCLEAN_UNZIPPED/$student_id
	# ============
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
		mapfile -t project_class_unclean_location < <(fd -Ipt file "${PROJECT_CLASS}" "${student_submission_unzipped_unclean}")
		num_file_matches="${#project_class_unclean_location[@]}"
		if [[ "${num_file_matches}" -gt 1 ]];
		then
			echo "${student_id}: Too many files matching ${PROJECT_CLASS}. Aborting..."
			ok=false
			break
		elif [[ "${num_file_matches}" -lt 1 ]];
		then
			echo "${student_id}: No files matching ${PROJECT_CLASS}. Aborting..."
			ok=false
			break
		fi 
		clean_dest="${student_submission_unzipped_clean}${PROJECT_CLASS}"
		mkdir -p "$(dirname "${clean_dest}")"
		if ! mv "${project_class_unclean_location[0]}" "${clean_dest}"; then
			echo "Failed to move ${project_class_unclean_location[0]} to ${clean_dest}. Aborting..."
			ok=false
			break
		fi
	done
	if ! $ok; then
		continue
	fi
	test_file_dest_dir="${CLEAN_UNZIPPED}${student_id}/${TEST_CLASS_DEST}"
	mkdir -p "${test_file_dest_dir}"
	if ! cp "${TEST_CLASS_ABS_PATH}" "${test_file_dest_dir}${TEST_CLASS}"; then
		echo "Failed to copy ${TEST_CLASS_ABS_PATH} to ${test_file_dest_dir}${TEST_CLASS}. Aborting..."
		continue
	fi
	continue

	# ============
	# Execute Program Securely
	# ============
	# TODO
	# - Create new user
	# - Switch permission of dest to user. 
	# - Run program as user
	# Run submission and write output to $OUTPUT
	if ! cd "${student_submission_unzipped_clean}"; then
		echo "Failed to cd into ${student_submission_unzipped_clean}. Aborting..."
		continue
	fi
	
	result_dest="${RESULTS}${student_id}"
	if ! java "${TEST_CLASS}" "${PROJECT_CLASSES[@]}" &> "${result_dest}";
	then
		echo "Failed to run ${student_id}'s submission"
	fi

	# TODO: Switch back to root. Delete user. cd back
	if ! cd - > /dev/null; then
		echo "Failed to cd back from ${student_submission_unzipped_clean}. Aborting..."
		continue
	fi
done

# Clean up
rm -rf "${ZIPPED}" "${UNCLEAN_UNZIPPED}" 
