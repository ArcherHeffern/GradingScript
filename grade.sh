#!/usr/bin/env bash

set -euo pipefail 
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# About: Autograder for Moodle submitted programming assignments
# Author: Archer Heffern
# OS: Ubuntu 24.04.2
# Runtime: bash 5.2.21
#
# TODO
# - Paralellize with GNU Parallel
# - Format output for easier grading
# - Make easier to capture output of running program (debug mode? -d)
#
# Bugs
# - Extraction of tar.gz not implemented
# - go test not supported

# ============
# Globals: All paths should be relative to this executable. All directories should end with /
# ============
# - Configurable Constants
LANG= 				# "java" | "go"
TEST_CLASS= 		# Cannot have multiple periods. java -cp... depends on this!
TEST_CLASS_DEST=
PROJECT_CLASSES=

############
# Past PA Configurations
############
# - COSI 131 PA1: Queues
# LANG="java" 
# TEST_CLASS="Test2.java" 
# TEST_CLASS_DEST="main/"
# PROJECT_CLASSES=("main/PCB.java" "main/ProcessManager.java" "main/Queue.java")

# - COSI 147 Lab 3b: PbService
LANG="go" 
TEST_CLASS="test_test.go" 
TEST_CLASS_DEST="viewservice/" 
PROJECT_CLASSES=("go.mod" "viewservice/client.go" "viewservice/common.go" "viewservice/server.go" "pbservice/client.go" "pbservice/common.go" "pbservice/server.go")


# ============
# Global Constants
# ============
RESULTS="results.csv"
UNCLEAN_UNZIPPED="unclean_unzipped/"
CLEAN_UNZIPPED="clean_unzipped/"
ZIPPED="zipped/"
MOODLE_SUBMISSION_EXTENSION="_assignsubmission_file"
NOK_PROJECT="nok${MOODLE_SUBMISSION_EXTENSION}"
NOK_PROJECT_ZIP="${NOK_PROJECT}.zip"

if [[ ! -f "${TEST_CLASS}" ]]; 
then
	echo "Error: Test Class does not exist at ${TEST_CLASS}."
	exit 1
fi

DEPENDENCIES=('fdfind' 'firejail' 'zip' 'unzip' 'jq' 'fzf')
for DEPENDENCY in "${DEPENDENCIES[@]}"; do
	if ! command -v "${DEPENDENCY}" > /dev/null 2>&1; then
		echo >&2 "Script requires '${DEPENDENCY}' but isn't installed. Aborting."
		exit 1
	fi
done

function print_help {
	echo "Usage: ${0} [-achmnrsz] zipfile"
	echo "-a|--all: (Default) Grade all submissions in submission_zipfile"
	echo "-c|--cache: Default except when using --regrade. Skips students with results in \$RESULTS"
	echo "-h|--help: Print help message"
	echo "-m|--moodle: (default) Grade a moodle submission zipfile"
	echo "-n|--no-cache: Overwrites previous results if they exist, or appends to \$RESULTS"
	echo "-r|--regrade: Regrades a student submission by recompiling their files in clean_unzipped"
	echo "-s|--select: Select a student submission to extract and run"
	echo "-z|-zipfile: Grade a single zipfile instead of moodle zipfile. No other options will apply"
}

# ============
# Process arguments
# ============
INPUT_ZIPFILE=
SELECT_STUDENT="false"
REGRADE="false"
CACHE="true"
TARGET="moodle" # moodle | zipfile


for OPTION in "${@:1}"; do
	case "${OPTION}" in
		-a|--all) REGRADE=false; SELECT_STUDENT=false;;
		-c|--cache) CACHE=true;;
		-h|--help) print_help; exit 0;;
		-m|--moodle) TARGET="moodle";;
		-n|--no-cache) CACHE=false;;
		-r|--regrade) SELECT_STUDENT=true; REGRADE=true; CACHE=false;;
		-s|--select) SELECT_STUDENT=true;;
		-z|--zipfile) TARGET="zipfile";;
		*) INPUT_ZIPFILE="${OPTION}";;
	esac
done

# Validate arguments
$CACHE && $REGRADE && { echo "Cannot set --cache and --regrade"; exit 1; };

[ "$TARGET" = "zipfile" ] && $SELECT_STUDENT && ! $REGRADE && { echo "No options apply when using --zipfile option"; exit 1; }

if [[ -z "${INPUT_ZIPFILE}" ]]; then 
	print_help
	exit 1
fi

if [[ ! -f "${INPUT_ZIPFILE}" ]]; then 
	echo "Error: ${INPUT_ZIPFILE} does not exist"
	exit 1
fi

function escape {
	# Escapes a line according to csv format
	# Replaces each double quote with two double quotes and double quotes the line
	# eg. 'he"l"o' -> '"he""l""o"'
	# Usage: escape 'unquoted_line'
	unquoted_line="${1}"

	quoted="$(echo "${unquoted_line}" | sed 's/"/""/g')"
	echo "\"${quoted}\""
}

function write_row {
	# If student_id is already in $RESULTS, delete this entry 
	# append the row
	student_id="${1}"
	row="${2}"

	sed -i "/^\"${student_id}\"/,/^\"${student_id}\"$/d" "$RESULTS"
	echo -e "$row" >> "$RESULTS"
}

if [[ "$SELECT_STUDENT" = true ]]; then
	mapfile -t student_ids < <( \
		unzip -l -O UTF-8 "${INPUT_ZIPFILE}" \
		| grep -Po '[a-zA-Z][a-zA-Z ]*_\d+_assignsubmission_file' \
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

# Reset: Remove $ZIPPED, $UNZIPPED, and $RESULTS
rm -rf   "$ZIPPED" "$UNCLEAN_UNZIPPED" "$NOK_PROJECT" "$NOK_PROJECT_ZIP"
mkdir -p "$ZIPPED" "$UNCLEAN_UNZIPPED"
touch "$RESULTS"
if [[ "$REGRADE" = false && "$SELECT_STUDENT" = false ]]; then
	rm -rf "${CLEAN_UNZIPPED}"
	mkdir -p "${CLEAN_UNZIPPED}"
fi

if [[ "$TARGET" == "zipfile" ]]; then
	mkdir "$NOK_PROJECT"
	cp "$INPUT_ZIPFILE" "$NOK_PROJECT"
	zip -r "$NOK_PROJECT_ZIP" "${NOK_PROJECT}/${INPUT_ZIPFILE}"
	rm -rf "${NOK_PROJECT}"
	INPUT_ZIPFILE="$NOK_PROJECT_ZIP"
fi

# Unzip all moodle zipfile
unzip -O UTF-8 "${INPUT_ZIPFILE}" -d "${ZIPPED}" > /dev/null

# Process all submissions
mapfile -t student_submission_groups < <(fdfind -I -t directory "${MOODLE_SUBMISSION_EXTENSION}$" "${ZIPPED}")

test_names=()
waiting_to_write=()
results_existed="false"
if [[ -s "$RESULTS" ]]; then
	results_existed="true"
fi

for student_submission_group in "${student_submission_groups[@]}"; do
	student_id="$(echo $(basename "${student_submission_group}") | cut -d'_' -f1)"
	student_submission_unzipped_clean="${CLEAN_UNZIPPED}${student_id}/"
	if [[ "$SELECT_STUDENT" = true && "${student_id}" != "${SELECTED_STUDENT}" ]]; then
		continue
	fi

	$CACHE && grep -Plq "^\"$student_id\"" "$RESULTS" && { echo "skipping ${student_id}..."; continue; }
	echo "=== Running ${student_id}'s submission ==="
	notes=()
	import_errors=()
	import_warnings=()
	compile_errors=""
	tests_passed=()
	test_fail_reason=()
	for _ in "0"; do
		if [[ "${REGRADE}" = false ]]; then
			# ============
			# Import Project
			# ============
			# - Unzip submission and place in $UNCLEAN_UNZIPPED/$student_id
			mapfile -t student_submissions < <(fdfind -I -e 'zip' -e 'tar.gz' . "${student_submission_group}")
			if [[ "${#student_submissions[@]}" -gt 1 ]]; then
				import_errors+=('Multiple submissions found. Skipping...')
				continue
			elif [[ "${#student_submissions[@]}" -lt 1 ]]; then
				import_errors+=('No submission found. Skipping...')
				continue
			fi

			student_submission_zipped="${student_submissions[0]}"
			student_submission_unzipped_unclean="${UNCLEAN_UNZIPPED}${student_id}/"
			student_submission_zipped_basename=$(basename "${student_submission_zipped}")
			extension="${student_submission_zipped_basename#*.}"
			case "$extension" in 
				"tar.gz") 
					mkdir "$student_submission_unzipped_unclean"
					if ! tar --directory="${student_submission_unzipped_unclean}" -xzf "${student_submission_zipped}" &> /dev/null; then
						import_errors+=("Failed to unzip ${student_submission_zipped}")
						break
					fi
					;;
				"zip") 
					if ! unzip -q "${student_submission_zipped}" -d "${student_submission_unzipped_unclean}"; then
						import_errors+=("Failed to unzip ${student_submission_zipped}")
						break
					fi
					;;
				*) 
					import_errors+=("Unrecognized submission extension ${extension}")
					continue;;
			esac

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
				mapfile -t project_class_unclean_location < <(fdfind -Ipt file "${PROJECT_CLASS}" "${student_submission_unzipped_unclean}")
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
					mapfile -t project_class_unclean_location < <(fdfind -Ipt file "$(basename "${PROJECT_CLASS}")" "${student_submission_unzipped_unclean}")
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
		# For each project type:
		# 	run program. Output results to random file. 
		# 	Get test_names if not yet found
		# 	Write header to project if not exists. Must start and end with student_id. Last student_id must be on its own line. 
		# 	tests_passed 		bool[]
		# 	test_fail_reason 	string[]
		# 	
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
			java -cp "$(realpath "${student_submission_unzipped_clean}")" "$(echo "${TEST_CLASS_DEST}${TEST_CLASS}" | cut -d'.' -f1)" -- "${results_dest}" 
		then
			echo "Failed to run ${student_id}'s submission. Perhaps you tried to regrade a submission not in clean_unzipped?" # TODO: Should I handle this? 
			continue
		fi
		# Parse Results
		if [[ "${#test_names[@]}" -eq 0 ]]; then
			mapfile -t test_names < <(jq '.[].name' "${student_submission_unzipped_clean}${results_dest}")
			# Write header
			header="student_id,notes,import errors,import warnings,compile errors"
			for test_name in "${test_names[@]}"; do
				header="${header},$(escape "${test_name} passed"),$(escape "${test_name} fail reason")"
			done
			header="${header},student_id_again"
			if [[ ! -s "${RESULTS}" ]]; then
				echo "${header}" > "${RESULTS}"
			elif [[ $results_existed != "true" ]]; then
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
			fail_reason="${test_fail_reason[${index}]:1: -1}"
		fi
		row="${row},$(escape "${test_passed}"),$(escape "${fail_reason}")"
	done
	row="${row},\\n$(escape "${student_id}")"

	if [[ "${#test_names[@]}" -eq 0 ]]; then
		waiting_to_write+=("${row}")
	else
		for deferred_row in "${waiting_to_write[@]}"; do # !Untested. Triggers if first student doesn't pass all tests
			for index in "${!test_names[@]}"; do
				deferred_row="${deferred_row},\"false\",\"\""
			done
			write_row "$student_id" "$deferred_row"
		done
		deferred_row=()
		write_row "$student_id" "$row"
	fi

done
for deferred_row in "${waiting_to_write[@]}"; do # !Untested. Triggers if first student doesn't pass all tests
	for index in "${!test_names[@]}"; do
		deferred_row="${deferred_row},\"false\",\"\""
	done
	write_row "$student_id" "$deferred_row"
done

# Clean up
echo "Cleaning up..."
rm -rf "$ZIPPED" "$UNCLEAN_UNZIPPED" "$NOK_PROJECT" "$NOK_PROJECT_ZIP"
