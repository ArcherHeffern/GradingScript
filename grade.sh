#!/usr/bin/env bash

set -euo pipefail 

# TODO
# - Support comparing student output with expected output and saving as diff
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

DEPENDENCIES=('firejail' 'zip' 'jq' 'fzf')
for DEPENDENCY in "${DEPENDENCIES[@]}"; do
	if ! command -v "${DEPENDENCY}" > /dev/null 2>&1; then
		echo >&2 "Script requires '${DEPENDENCY}' but isn't installed. Aborting."
		exit 1
	fi
done

function escape {
	# Escapes a line according to csv format
	# Replaces each double quote with two double quotes and double quotes the line
	# eg. 'he"l"o' -> '"he""l""o"'
	# Usage: escape '<string>'
	unquoted="${1}"
	quoted="$(echo "${unquoted}" | sed 's/"/""/g')"
	echo "\"${quoted}\""
}

# ============
# Process arguments
# ============
INPUT_ZIPFILE="${1-}"
SELECT_STUDENT=false
REGRADE=false

if [[ -z "${INPUT_ZIPFILE}" ]]; then
	echo "Usage: ${0} submissions_zipfile [-sr]"
	exit 1
fi 

if [[ ! -f "${INPUT_ZIPFILE}" ]]; then 
	echo "Error: ${INPUT_ZIPFILE} does not exist"
	exit 1
fi

if [[ "${2-}" = "-s" ]]; then
	SELECT_STUDENT=true
fi

if [[ "${2-}" = "-r" ]]; then
	SELECT_STUDENT=true
	REGRADE=true
fi

# ============
# Globals: All paths should be relative to this executable
# ============
# - Configurable Constants
RESULTS="results.csv"
TEST_CLASS="Test2.java" # Cannot have multiple periods. java -cp... depends on this!
TEST_CLASS_DEST="main/"
PROJECT_CLASSES=("main/PCB.java" "main/ProcessManager.java" "main/Queue.java")
# - Internal Constants
UNCLEAN_UNZIPPED="unclean_unzipped/"
CLEAN_UNZIPPED="clean_unzipped/"
ZIPPED="zipped/"
MOODLE_SUBMISSION_EXTENSION="_assignsubmission_file"

if [[ ! -f "${TEST_CLASS}" ]]; 
then
	echo "Error: Test Class does not exist at ${TEST_CLASS}."
	exit 1
fi

# Reset: Remove $ZIPPED, $UNZIPPED, and $RESULTS
rm -rf   "${ZIPPED}" "${UNCLEAN_UNZIPPED}" "${RESULTS}"
mkdir -p "${ZIPPED}" "${UNCLEAN_UNZIPPED}"
if [[ $REGRADE = false ]]; then
	rm -rf "${CLEAN_UNZIPPED}"
	mkdir -p "${CLEAN_UNZIPPED}"
fi

# Unzip all moodle zipfile
unzip "${INPUT_ZIPFILE}" -d "${ZIPPED}" > /dev/null

# Process all submissions
mapfile -t student_submission_groups < <("${FD_CMD}" -I -t directory "${MOODLE_SUBMISSION_EXTENSION}$" "${ZIPPED}")

if [[ $SELECT_STUDENT = true ]]; then
	mapfile -t student_ids < <( \
		unzip -l "${INPUT_ZIPFILE}" \
		| grep -Po '[a-zA-Z ]*_\d+_assignsubmission_file' \
		| cut -d'_' -f1 \
		| sort \
		| uniq \
	)
	SELECTED_STUDENT="$(printf "%s\n" "${student_ids[@]}" | fzf)"
	if [[ $? -ne 0 ]]; then
		echo 2> "No student selected. Exiting..."
		exit 0
	fi

fi

test_names=()
waiting_to_write=()
for student_submission_group in "${student_submission_groups[@]}"; do
	student_id="$(echo $(basename "${student_submission_group}") | cut -d'_' -f1)"
	student_submission_unzipped_clean="${CLEAN_UNZIPPED}${student_id}/"
	if [[ "${SELECT_STUDENT}" = true && "${student_id}" != "${SELECTED_STUDENT}" ]]; then
		continue
	fi
	notes=()
	import_errors=()
	import_warnings=()
	compile_errors=""
	tests_passed=()
	test_fail_reason=()
	echo "=== Running ${student_id}'s submission ==="
	for _ in "0"; do
		if [[ "${REGRADE}" = false ]]; then
			# ============
			# Import Project
			# ============
			# - Unzip submission and place in $UNCLEAN_UNZIPPED/$student_id
			mapfile -t student_submissions < <("${FD_CMD}" -I -e 'zip' . "${student_submission_group}")
			if [[ "${#student_submissions[@]}" -gt 1 ]]; then
				import_errors+=('Multiple submissions found. Skipping...')
				break
			elif [[ "${#student_submissions[@]}" -lt 1 ]]; then
				import_errors+=('No submission found. Skipping...')
				break
			fi

			student_submission_zipped="${student_submissions[0]}"
			student_submission_unzipped_unclean="${UNCLEAN_UNZIPPED}${student_id}/"
			if ! unzip -q "${student_submission_zipped}" -d "${student_submission_unzipped_unclean}";
			then
				import_errors+=("Failed to unzip ${student_submission_zipped}")
				continue
			fi

			# ============
			# Submission Cleaning and Setup
			# ============
			# - Verify script contains all $PROJECT_CLASSES
			# - Move all project classes to $CLEAN_UNZIPPED/$student_id
			# - copy $TEST_CLASS to $CLEAN_UNZIPPED/$student_id/$TEST_CLASS_DEST/$TEST_CLASS
			ok=true
			for PROJECT_CLASS in "${PROJECT_CLASSES[@]}"; do
				clean_dest="${student_submission_unzipped_clean}${PROJECT_CLASS}"
				package="$(dirname "${PROJECT_CLASS}")"
				mapfile -t project_class_unclean_location < <("${FD_CMD}" -Ipt file "${PROJECT_CLASS}" "${student_submission_unzipped_unclean}")
				num_file_matches="${#project_class_unclean_location[@]}"

				if [[ "${num_file_matches}" -gt 1 ]];
				then
					import_errors+=("Too many files matching ${PROJECT_CLASS}.")
					ok=false
					break
				elif [[ "${num_file_matches}" -lt 1 ]];
				then
					# Attempted coercion of file into correct package. If this fails not my problem
					# Changes package of a file matching basename ${PROJECT_CLASS} to expected package in-place
					mapfile -t project_class_unclean_location < <("${FD_CMD}" -Ipt file "$(basename "${PROJECT_CLASS}")" "${student_submission_unzipped_unclean}")
					num_file_matches="${#project_class_unclean_location[@]}"
					if [[ "${num_file_matches}" -gt 1 ]];
					then
						import_errors+=("Too many files matching $(basename ${PROJECT_CLASS}).")
						ok=false
						break
					elif [[ "${num_file_matches}" -lt 1 ]];
					then
						import_errors+=("No files matching $(basename ${PROJECT_CLASS}).")
						ok=false
						break
					fi
					# TODO: Remove ${student_submission_unzipped_unclean} from front of ${project_class_unclean_location[0]}
					import_warnings+=("Coerced ${project_class_unclean_location[0]} to ${PROJECT_CLASS}")
				else
					# Verify in right package and contains package declaration at top
					if ! grep -lP "^\s*package\s+${package}\s*;\s*$" "${project_class_unclean_location}" &> /dev/null; then
						import_warnings+=("${PROJECT_CLASS} found in correct location but missing proper package declaration")
					fi
				fi 
				mkdir -p "$(dirname "${clean_dest}")"
				if ! sed -r 's/\s*package.*//' "${project_class_unclean_location[0]}" | sed "1i package ${package};" > "${clean_dest}"; then
					import_errors+=("Failed to coerce and move \'${project_class_unclean_location[0]}\' to \'${clean_dest}\'.")
					ok=false
					break
				fi
				rm "${project_class_unclean_location[0]}"
			done
			if ! $ok; then
				break
			fi

			test_file_dest_dir="${student_submission_unzipped_clean}${TEST_CLASS_DEST}"
			mkdir -p "${test_file_dest_dir}"
			if ! cp "$(realpath "${TEST_CLASS}")" "${test_file_dest_dir}${TEST_CLASS}"; then
				import_errors+=("Failed to copy \'$(realpath ${TEST_CLASS})\' to \'${test_file_dest_dir}${TEST_CLASS}\'.")
				continue
			fi
		fi

		# ============
		# Compile and Run Program Securely
		# ============
		# Writes results to a random file named during runtime HAHA!
		output="$(
		{ firejail \
			--noprofile \
			--read-only=/ \
			--private-cwd="$(realpath "${student_submission_unzipped_clean}")" \
			--whitelist="$(realpath "${student_submission_unzipped_clean}")" \
			javac "${TEST_CLASS_DEST}${TEST_CLASS}" "${PROJECT_CLASSES[@]}" \
			|| true
		} 2>&1 > /dev/null | tail -n+3 | head -n-2
		)"
		if [[ "${#output}" -ne 0 ]]; then # !scary!
			compile_errors="${output}"
			continue
		fi

		results_dest="results_${RANDOM}.json"
		if ! firejail \
			--noprofile \
			--read-only=/ \
			--private-cwd="$(realpath "${student_submission_unzipped_clean}")" \
			--whitelist="$(realpath "${student_submission_unzipped_clean}")" \
			java -cp "$(realpath "${student_submission_unzipped_clean}")" "$(echo "${TEST_CLASS_DEST}${TEST_CLASS}" | cut -d'.' -f1)" -- "${results_dest}" &> /dev/null
		then
			echo "Failed to run ${student_id}'s submission" # TODO: Should I handle this? 
			continue
		fi
		# Parse Results
		if [[ "${#test_names[@]}" -eq 0 ]]; then
			mapfile -t test_names < <(jq -r '.[].name' "${student_submission_unzipped_clean}${results_dest}")
			# Write header
			header="student_id,notes,import errors,import warnings,compile errors"
			for test_name in "${test_names[@]}"; do
				header="${header},$(escape "${test_name} passed"),$(escape "${test_name} feedback")"
			done
			if [[ ! -s "${RESULTS}" ]]; then
				echo "${header}" > "${RESULTS}"
			else
				sed -i "1i ${header}" "${RESULTS}"
			fi
		fi
		mapfile -t tests_passed < <(jq '.[].pass' "${student_submission_unzipped_clean}${results_dest}")
		mapfile -t test_fail_reason < <(jq '.[].reason' "${student_submission_unzipped_clean}${results_dest}")
	done
	# ============
	# Write results to csv
	# ============
	escaped_student_id="$(escape "${student_id}")"
	escaped_collated_notes=""
	for note in "${notes[@]}"; do
		escaped_collated_notes="${escaped_collated_notes}${note}\n"
	done
	escaped_collated_notes="$(escape "${escaped_collated_notes}")"
	escaped_collated_import_errors=""
	for import_error in "${import_errors[@]}"; do
		escaped_collated_import_errors="${escaped_collated_import_errors}${import_error}\n"
	done
	escaped_collated_import_errors="$(escape "${escaped_collated_import_errors}")"
	escaped_collated_import_warnings=""
	for import_warning in "${import_warnings[@]}"; do
		escaped_collated_import_warnings="${escaped_collated_import_warnings}${import_warning}\n"
	done
	escaped_collated_import_warnings="$(escape "${escaped_collated_import_warnings}")"
	escaped_collated_compile_errors="$(escape "${compile_errors}")"
	row="${escaped_student_id},${escaped_collated_notes},${escaped_collated_import_errors},${escaped_collated_import_warnings},${escaped_collated_compile_errors}"
	for index in "${!test_names[@]}"; do
		test_passed="false"
		fail_reason=""
		if [[ "${#tests_passed[@]}" -gt 0 ]]; then
			test_passed="${tests_passed[${index}]}"
			fail_reason_no_quotes="${test_fail_reason[${index}]}"
			fail_reason="${fail_reason_no_quotes:1:$((${#fail_reason_no_quotes} - 2))}"
		fi
		row="${row},$(escape "${test_passed}"),$(escape "${fail_reason}")"
	done

	if [[ "${#test_names[@]}" -eq 0 && $SELECT_STUDENT != true ]]; then
		waiting_to_write+=("${row}")
	else
		for deferred_row in "${waiting_to_write[@]}"; do # !Untested. Triggers if first student doesn't pass all tests
			for index in "${!test_names[@]}"; do
				deferred_row="${deferred_row},\"false\",\"\""
			done
			echo -e "${deferred_row}" >> "${RESULTS}"
		done
		deferred_row=()
		echo -e "${row}" >> "${RESULTS}"
	fi

done

# Clean up
echo "Cleaning up..."
rm -rf "${ZIPPED}" "${UNCLEAN_UNZIPPED}" 
