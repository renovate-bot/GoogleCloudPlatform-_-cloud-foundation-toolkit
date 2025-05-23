#!/usr/bin/env bash

# Copyright 2019 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Trap handler to delete the temporary directory created by
# setup_trap_handler() and used by maketemp()
finish() {
  if [[ -n "${DELETE_AT_EXIT:-}" ]]; then
    rm -rf "$DELETE_AT_EXIT"
  fi
}

# Create a temporary directory and store the path in DELETE_AT_EXIT.  Register
# a trap handler to automatically remove this temporary directory.  Intended
# for use with maketemp() to automatically clean up temporary files, especially
# those used to store credentials.
setup_trap_handler() {
  if [[ -z "${DELETE_AT_EXIT+x}" ]]; then
    DELETE_AT_EXIT="$(mktemp -d)"
    readonly DELETE_AT_EXIT
  fi
  trap finish EXIT
}

# Integration testing requires different behavior for its trap handler (running
# `kitchen destroy` along with cleaning up the environment). Because you can't
# have more than one trap handler for a signal, this function sets up the trap
# handler to call the finish_integration() function unique to integration tests.
setup_trap_handler_integration() {
  setup_trap_handler
  trap finish_integration exit
}

# If DELETE_AT_EXIT is set (by setup_trap_handler), create a temporary file in
# the auto-cleaned up directory while avoiding overwriting TMPDIR for other
# processes.  Otherwise, create a temporary file or directory normally as per
# mktemp.
#
# shellcheck disable=SC2120 # (Arguments may be passed, e.g. maketemp -d)
maketemp() {
  if [[ -n "${DELETE_AT_EXIT:-}" ]]; then
    TMPDIR="${DELETE_AT_EXIT}" mktemp "$@"
  else
    mktemp "$@"
  fi
}

# find_files is a helper to exclude .git directories and match only regular
# files to avoid double-processing symlinks.
# You can ignore directories by setting two different environment variables of
#   relative escaped paths separated by a pipe
# (1) EXCLUDE_LINT_DIRS - all files pointed to by this variable are skipped
#                         during ANY USE of the find_files function
#     E.g.: EXCLUDE_LINT_DIRS="\./scripts/foo|\./scripts/bar"
# (2) EXCLUDE_HEADER_CHECK - all files pointed to by this variable are skipped
#                            ONLY WHEN the "for_header_check" flag is passed in
#     E.g.: EXCLUDE_HEADER_CHECK="\./config/foo_resource.yml|\./scripts/bar_script.sh"
find_files() {
  local pth="$1" find_path_regex="(" exclude_dirs=( ".*/\.git"
    ".*/\.terraform"
    ".*/\.terraform.lock.hcl"
    ".*/\.kitchen"
    ".*/.*\.class"
    ".*/.*\.png"
    ".*/.*\.jpg"
    ".*/.*\.jpeg"
    ".*/.*\.svg"
    ".*/.*\.ico"
    ".*/.*\.jar"
    ".*/.*\.parquet"
    ".*/.*\.pb"
    ".*/.*\.index"
    "\./autogen"
    "\./test/fixtures/all_examples"
    "\./test/fixtures/shared"
    "\./cache"
    "\./test/source\.sh" )
  shift

  # Concat all of the above dirs except the last, separated by a pipe
  for ((index=0; index<$((${#exclude_dirs[@]}-1)); ++index)); do
    find_path_regex+="${exclude_dirs[index]}|"
  done

  # Add any regex supplied to ignore other dirs
  if [[ -n "${EXCLUDE_LINT_DIRS-}" ]]; then
    find_path_regex+="${EXCLUDE_LINT_DIRS}"
    find_path_regex+="|"
  fi

  # if find_files is used for validating license headers
  if [ $1 = "for_header_check" ]; then
    # Add any files to be skipped for header check
    if [[ -n "${EXCLUDE_HEADER_CHECK-}" ]]; then
      find_path_regex+="${EXCLUDE_HEADER_CHECK}"
      find_path_regex+="|"
    fi
    shift
  fi

  # Concat last dir, along with closing paren
  find_path_regex+="${exclude_dirs[-1]})"
  # find_path_regex should be a string of this format:
  # (some_relative_path|another_relative_path)
  # ex: find_path_regex = (.*/\.git|.*/\.terraform|.*/\.kitchen|.*/.*\.png)

  # Note: Take care to use -print or -print0 when using this function,
  # otherwise excluded directories will be included in the output.
  find "${pth}" -regextype posix-egrep -regex "${find_path_regex}" \
    -prune -o -type f "$@"
}

# Compatibility with both GNU and BSD style xargs.
compat_xargs() {
  local compat=()
  # Test if xargs is GNU or BSD style.  GNU xargs will succeed with status 0
  # when given --no-run-if-empty and no input on STDIN.  BSD xargs will fail and
  # exit status non-zero If xargs fails, assume it is BSD style and proceed.
  # stderr is silently redirected to avoid console log spam.
  if xargs --no-run-if-empty </dev/null 2>/dev/null; then
    compat=("--no-run-if-empty")
  fi
  xargs "${compat[@]}" "$@"
}

# This function makes sure that the required files for
# releasing to OSS are present
function basefiles() {
  local fn required_files="LICENSE README.md"
  echo "Checking for required files ${required_files}"
  for fn in ${required_files}; do
    test -f "${fn}" || echo "Missing required file ${fn}"
  done
}

# This function runs the hadolint linter on
# every file named 'Dockerfile'
function lint_docker() {
  echo "Running hadolint on Dockerfiles"
  find_files . -name "Dockerfile" -print0 \
    | compat_xargs -0 hadolint
}

# This function creates TF_PLUGIN_CACHE_DIR if TF_PLUGIN_CACHE_DIR envvar is set
function init_tf_plugin_cache() {
  if [[ -n "$TF_PLUGIN_CACHE_DIR" ]]; then
    mkdir -p "$TF_PLUGIN_CACHE_DIR"
  fi
}

# This function runs 'terraform validate' against all
# directory paths which contain *.tf files.
function check_terraform() {
  set -e
  local rval rc
  rval=0

  init_tf_plugin_cache

  # fmt is before validate for faster feedback, validate requires terraform
  # init which takes time.
  echo "Running terraform fmt"
  while read -r file; do
    terraform fmt -diff -check=true -write=false "$file"
    rc="$?"
    if [[ "${rc}" -ne 0 ]]; then
      echo "Error: terraform fmt failed with exit code ${rc}" >&2
      echo "Check the output for diffs and correct using terraform fmt <dir>" >&2
      rval="$rc"
    fi
  done <<< "$(find_files . -name "*.tf" -print)"
  if [[ "${rval}" -ne 0 ]]; then
    return "${rval}"
  fi
  echo "Running terraform validate"
  # Change to a temporary directory to avoid re-initializing terraform init
  # over and over in the root of the repository.

  # If enable parallel, run validate in parallel
  if [[ "${ENABLE_PARALLEL:-}" -eq 1 ]]; then
    find_files . -name "*.tf" -print \
    | grep -v 'test/fixtures/shared' \
    | compat_xargs -n1 dirname \
    | sort -u \
    | parallel --keep-order --retries 3 --joblog /tmp/lint_log terraform_validate
    cat /tmp/lint_log
  else
    find_files . -name "*.tf" -print \
    | grep -v 'test/fixtures/shared' \
    | compat_xargs -n1 dirname \
    | sort -u \
    | compat_xargs -t -n1 terraform_validate
  fi
}

# This function runs 'go fmt' and 'go vet' on every file
# that ends in '.go'
function golang() {
  echo "Running go fmt and go vet"
  find_files . -name "*.go" -print0 | compat_xargs -0 -n1 go fmt
  find_files . -name "*.go" -print0 | compat_xargs -0 -n1 go vet
}

# This function runs the flake8 linter on every file
# ending in '.py'
function check_python() {
  echo "Running flake8"
  find_files . -name "*.py" -print0 | compat_xargs -0 flake8
}

# This function runs the shellcheck linter on every
# file ending in '.sh'
function check_shell() {
  echo "Running shellcheck"
  find_files . -name "*.sh" -print0 | compat_xargs -0 shellcheck -x
}

function check_trailing_whitespace() {
  echo -n 'Warning: check_trailing_whitespace is deprecated use ' >&2
  echo 'check_whitespace' >&2
  check_whitespace
}

# Check for common whitespace errors:
# Trailing whitespace at the end of line
# Missing newline at end of file
check_whitespace() {
  local rc
  echo "Checking for trailing whitespace"
  find_files . -print \
    | grep -v -E '\.(pyc|png|gz|swp|tfvars|mp4|zip|ico|jar|parquet|pb|index)$' \
    | compat_xargs grep -H -n '[[:blank:]]$'
  rc=$?
  if [[ ${rc} -eq 0 ]]; then
    printf "Error: Trailing whitespace found in the lines above.\n\n"
    ((rc++))
  else
    rc=0
  fi
  echo "Checking for missing newline at end of file"
  find_files . -print \
    | grep -v -E '\.(png|gz|tfvars|mp4|zip|ico|jar|parquet|pb|index)$' \
    | compat_xargs check_eof_newline
  return $((rc+$?))
}

# Helper function to facilitate switch to a 0.12 compatible doc generator:
#  - replaces `terraform_docs`s markers with `pre-commit-terraform`s
#    markers for `terraform_docs.sh` - a wrapper around `terraform_docs`
#  - removes `combine_docfiles.py` script
#  - adds a copy of `terraform_docs.sh` script
#  - adds `terraform_validate` script
function replace_doc_generator {
  local rval rc rmf old_script_path
  rval=0
  # Replace markers
  for rmf in $(find_files . -name 'README.md'); do
    if [ -f "${rmf}" ]; then
      sed -i '/autogen_docs_start/,/autogen_docs_end/{//!d}' "${rmf}"
      sed -i 's/\[\^]:\ (autogen_docs_start)/<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->/g' "${rmf}"
      sed -i 's/\[\^]:\ (autogen_docs_end)/<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->/g' "${rmf}"
    fi
  done
  # Replace script
  old_script_path=$(find . -name 'combine_docfiles.py')
  if [ -n "${old_script_path}" ]; then
    rm -rf "${old_script_path}"
    cd "$(dirname "${old_script_path}")" || exit
    wget https://raw.githubusercontent.com/terraform-google-modules/terraform-google-project-factory/main/helpers/terraform_{docs,validate} &>/dev/null
    rc=$?
    if [ $rc -ne 0 ]; then
      echo "Error: Doc Generator scripts have not been downloaded properly, please check/re-download them manually."
      ((rval++))
    else
      chmod +x ./terraform_{docs,validate}
    fi
    cd - >/dev/null
  fi
  # Re-generate docs
  generate_docs
  rc=$?
  if [ $rc -ne 0 ]; then
    echo -e "Error: Doc Generator failed. please check/re-generate them manually."
    ((rval++))
  fi
  return $((rval))
}

function generate_docs() {
  echo "Generating markdown docs with terraform-docs"
  local path
  while read -r path; do
    if [[ -e "${path}/README.md" ]]; then
      # script seem to be designed to work into current directory
      cd "${path}" && echo "Working in ${path} ..."
      terraform_docs.sh . && echo Success! || echo "Warning! Exit code: ${?}"
      cd - >/dev/null
    else
      echo "Skipping ${path} because README.md does not exist."
    fi
  done < <(find_files . -name '*.tf' -print0 \
    | compat_xargs -0 -n1 dirname \
    | sort -u)

  # disable opt in after https://github.com/GoogleCloudPlatform/cloud-foundation-toolkit/issues/1353
  if [[ "${ENABLE_BPMETADATA:-}" -ne 1 ]]; then
    echo "ENABLE_BPMETADATA not set to 1. Skipping metadata generation."
    return 0
  fi
  generate_metadata "${1-default}"
}

function generate_metadata() {
  echo "Generating blueprint metadata"
  arg=${1-default}
  # check if metadata was request with parameters
  if [ "${arg}" = "default" ]; then
    cft blueprint metadata
  elif [ "${arg}" = "display" ]; then
    cft blueprint metadata -d
  else
    eval "cft blueprint metadata $arg"
  fi

  if [ $? -ne 0 ]; then
    echo "Warning! Unable to generate metadata."
    return 1
  fi
  # add headers since comments are not preserved with metadata generation
  # TODO: b/260869608
  fix_headers
}

function check_metadata() {
  if [[ "${ENABLE_BPMETADATA:-}" -ne 1 ]]; then
    echo "ENABLE_BPMETADATA not set to 1. Skipping metadata validation."
    return 0
  fi

  echo "Validating blueprint metadata"
  cft blueprint metadata -v

  if [ $? -eq 0 ]; then
    echo "Success!"
  else
    echo "Warning! Unable to validate metadata."
    return 1
  fi
}

function check_tflint() {
  if [[ "${DISABLE_TFLINT:-}" ]]; then
    echo "DISABLE_TFLINT set. Skipping tflint check."
    return 0
  fi
  local rval
  setup_trap_handler
  rval=0
  echo "Checking for tflint"
  local path
    while read -r path; do
      local tflintCfg
      # skip any tf configs under test/
      if [[ $path == "./test"* ]];then
        echo "Skipping ${path}"
        continue
      fi
      # load default ruleset
      tflintCfg="/root/tflint/.tflint.example.hcl"
      # load if local repo ruleset
      if [[ -f "/workspace/.github/.tflint.repo.hcl" ]]; then
        tflintCfg="/workspace/.github/.tflint.repo.hcl"
      # if module, load tighter ruleset
      elif [[ $path == "." || $path == "./modules"* || $path =~ "^[0-9]+-.*" ]]; then
        tflintCfg="/root/tflint/.tflint.module.hcl"
      fi

      cd "${path}" && echo "Working in ${path} using ${tflintCfg}..."
      tflint --config=${tflintCfg} --no-color
      rc=$?
      if [[ "${rc}" -ne 0 ]]; then
        echo "tflint failed ${path} "
        ((rval++))
      else
        echo "tflint passed ${path} "
      fi
      cd - >/dev/null
    done < <(find_files . -name '*.tf' -print0 \
      | compat_xargs -0 -n1 dirname \
      | sort -u)
  return $((rval))
}

# Lint check to determine whether generate_docs() needs to be run by copying to
# a tmp directory, running generate_docs(), and then diffing the result.
function check_documentation() {
  local tempdir rval rc
  setup_trap_handler
  tempdir="${DELETE_AT_EXIT}/generate_docs"
  rval=0
  echo "Checking for documentation generation"
  rsync -axh \
    --exclude '*/.terraform' \
    --exclude '*/.kitchen' \
    --exclude 'autogen' \
    --exclude '*/.tfvars' \
    /workspace "${tempdir}" >/dev/null 2>/dev/null
  cd "${tempdir}/workspace"
  generate_docs >/dev/null 2>/dev/null
  # TODO: (b/261241276) preserve verion no. for release PR
  diff -r \
    --exclude=".terraform" \
    --exclude=".kitchen" \
    --exclude="autogen" \
    --exclude="*.tfvars" \
    --exclude="*metadata.yaml" \
    /workspace "${tempdir}/workspace"
  rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    echo "Error: Documentation generation has not been run, please run the"
    echo "'make docker_generate_docs' command and commit the above changes."
    ((rval++))
  fi
  cd /workspace
  rm -Rf "${tempdir}"
  return $((rval))
}

# Generate modules from tempalte files in 'autogen' folder
function generate_modules() {
  if [[ -e /workspace/autogen_modules.json ]]; then
    autogen_modules=$(jq '.' /workspace/autogen_modules.json)
    python3 /usr/local/bin/generate_modules.py "$autogen_modules"

    # formatting the generated modules since formatting does not apply
    # to jinja templates
    echo "Running terraform fmt"
    terraform fmt -recursive
  fi
}

# Post a comment to GitHub informing PR author about linting checks status
# requires a secret with PAT called gh-pat-token and cloud build SA with roles/secretmanager.secretAccessor
function post_lint_status_pr_comment() {
  export GITHUB_PAT_TOKEN=$(gcloud secrets versions access latest --secret="gh-pat-token")
  final_message=$(/usr/local/bin/test_lint.sh --markdown --contrib-guide=../blob/main/CONTRIBUTING.md)
  if [ -z "$final_message" ]; then
  final_message="Thanks for the PR! 🚀<br/>✅ Lint checks have passed."
  fi
  python3 /usr/local/bin/gh_lint_comment.py -r "${REPO_NAME}" -p "${_PR_NUMBER}" -c "${final_message}"
}

# Check that module generation has happened
function check_generate_modules() {
  if [[ -e /workspace/autogen_modules.json ]]; then
    local tempdir rval rc
    setup_trap_handler
    tempdir=$(mktemp -d)
    rval=0
    echo "Checking submodule's files generation"
    rsync -axh \
      --exclude '*/.terraform' \
      --exclude '*/.kitchen' \
      /workspace "${tempdir}" >/dev/null 2>/dev/null
    cd "${tempdir}/workspace" || exit 1
    generate_modules >/dev/null 2>/dev/null
    generate_docs >/dev/null 2>/dev/null
    diff -r \
      --exclude=".terraform" \
      --exclude=".kitchen" \
      --exclude=".git" \
      /workspace "${tempdir}/workspace"
    rc=$?
    if [[ "${rc}" -ne 0 ]]; then
      echo "Error: submodule's files generation has not been run, please run the"
      echo "'make build' command and commit changes"
      ((rval++))
    fi
    cd /workspace || exit 1
    rm -Rf "${tempdir}"
    return $((rval))
  fi
}

function prepare_test_variables() {
  echo "Preparing terraform.tfvars files for integration tests"
  #shellcheck disable=2044
  for i in $(find ./test/fixtures -type f -name terraform.tfvars.sample); do
    destination=${i/%.sample/}
    if [ ! -f "${destination}" ]; then
      cp "${i}" "${destination}"
      echo "${destination} has been created. Please edit it to reflect your GCP configuration."
    fi
  done
}

function check_headers() {
  echo "Checking file headers"
  # Use the exclusion behavior of find_files(); a second argument
  # "for_header_check" is passed in, to ensure filtering based on the evironment
  # variable EXCLUDE_HEADER_CHECK is done only when find_files is called here
  find_files . for_header_check -type f -print0 | compat_xargs -0 addlicense -check 2>&1
}

# Add license headers to the files in the project. If a list of files are provided
# as an input argument then those files are updated to have the license header.
# If not find_files() function is used to get the list of applicable files from
# the current directory and those files are updated.
function fix_headers() {
  echo "Adding file license headers"
  YEAR=$(date +'%Y')
  if [ $# -eq 0 ]
  then
    find_files . for_header_check -type f -print0 | compat_xargs -0 addlicense -y "$YEAR"
  else
    addlicense -y "$YEAR" "$@"
  fi
}

# Given SERVICE_ACCOUNT_JSON with the JSON string of a service account key,
# initialize the SA credentials for use with:
# 1: terraform
# 2: gcloud (passes SA creds implicitly to gsutil and bq-script)
# 3: Kitchen and inspec
#
# Add service acocunt support for additional tools as needed, preferring the
# use of environment varialbes so that the variable may be removed and an
# instance service account with Google Managed Keys used instead.
init_credentials() {
  if [[ -z "${SERVICE_ACCOUNT_JSON:-}" ]]; then
    echo "Error: SERVICE_ACCOUNT_JSON must contain the JSON string (not the" >&2
    echo "file path) of the service account credentials.  For example:" >&2
    # shellcheck disable=SC2016
    echo 'export SERVICE_ACCOUNT_JSON=$(< ~/.credentials/my-sa-key.json)' >&2
    return 1
  fi

  local tmpfile
  # shellcheck disable=SC2119
  tmpfile="$(maketemp)"
  echo "${SERVICE_ACCOUNT_JSON}" > "${tmpfile}"

  # Terraform and most other tools respect GOOGLE_CREDENTIALS
  # https://www.terraform.io/docs/providers/google/provider_reference.html#credentials-1
  export GOOGLE_CREDENTIALS="${SERVICE_ACCOUNT_JSON}"

  # gcloud variables
  export CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="${tmpfile}"

  # InSpec respects GOOGLE_APPLICATION_CREDENTIALS
  # https://github.com/inspec/inspec-gcp#create-credentials-file-via
  export GOOGLE_APPLICATION_CREDENTIALS="${tmpfile}"

  # Login to GCP for using bq-script and gsutil
  gcloud auth activate-service-account --key-file="${GOOGLE_APPLICATION_CREDENTIALS}"
}

init_credentials_if_found() {
   if [[ -z "${SERVICE_ACCOUNT_JSON:-}" ]]; then
    echo "Proceeding using application default credentials"
  else
    init_credentials
  fi
}

# Prepare the setup environment
prepare_environment() {
  set -eu

  init_credentials_if_found

  cd test/setup/ || exit
  terraform init
  terraform apply -auto-approve

  if [ -f make_source.sh ]; then
    echo "Found test/setup/make_source.sh. Using it for additional explicit environment configuration."
    ./make_source.sh
  fi
}

 # Destroy the setup environment
cleanup_environment() {
  set -eu

  init_credentials_if_found

  cd test/setup/ || exit

  terraform init
  terraform destroy -auto-approve
}

setup_environment() {
  echo 'Warning: setup_environment is deprecated.  Use init_credentials instead.' >&2
  init_credentials
}

# Source environment variables with tf outputs from the setup folder and/or a source file, if found
source_test_env() {
  if [ -d test/setup ]; then
    # shellcheck disable=SC1091
    source <(python3 /usr/local/bin/export_tf_outputs.py --path=test/setup)
  else
    if [ -f test/source.sh ]; then
      echo "Warning: test/setup not found. Will only use test/source.sh to configure environment."
    else
      echo "Warning: Neither test/setup or test/source.sh found. Assuming environment configured elsewhere."
    fi
  fi
  if [ -f test/source.sh ]; then
    echo "Found test/source.sh. Using it for additional explicit environment configuration."
    # shellcheck disable=SC1091
    source test/source.sh
  fi
}

# Run kitchen tasks with sourced credentials
kitchen_do() {
  source_test_env
  init_credentials

  local command="$1"
  shift
  case "$command" in
    create | converge | destroy | setup | test | verify)
      kitchen "$command" "$@" --test-base-path="$KITCHEN_TEST_BASE_PATH"
      ;;
    *)
      kitchen "$command" "$@"
      ;;
  esac
}

# This function is called by /usr/local/bin/test_integration.sh and can be
# overridden on a per-module basis to implement additional steps.
run_integration_tests() {
  source_test_env

  init_credentials
  kitchen create --test-base-path="$KITCHEN_TEST_BASE_PATH"
  kitchen converge --test-base-path="$KITCHEN_TEST_BASE_PATH"
  kitchen verify --test-base-path="$KITCHEN_TEST_BASE_PATH"
}

# Integration testing requires `kitchen destroy` to be called up before the
# environment is cleaned up.
finish_integration() {
  local rv=$?
  kitchen destroy --test-base-path="$KITCHEN_TEST_BASE_PATH"
  finish
  exit "${rv}"
}


# This function is called by /usr/local/bin/test_validator.sh and can be
# overridden on a per-module basis to implement additional steps.
run_terraform_validator() {
  source_test_env
  init_credentials

  tf_full_path="$1"
  project="$2"
  policy_file_path="$3"


  export tf_name=$(basename -- $tf_full_path)
  export base_dir=$(pwd)
  export tmp_plan="${base_dir}/test/integration/tmp/tfvt/${tf_name}"


  echo "*************** TFV VALIDATE ************************"
  echo "      Validating $tf_name at path $tf_full_path"
  echo "      Using policy from: $policy_file_path "
  echo "      in project: $project"
  echo "*****************************************************"


  if [ ! -d "$tmp_plan" ]; then
      mkdir -p "$tmp_plan/" || exit 1
  fi

  if [ -z "$policy_file_path" ]; then
      echo "no policy repo found! Check the argument provided for policysource to this script."
      echo "https://github.com/GoogleCloudPlatform/terraform-validator/blob/main/docs/policy_library.md"
      exit 1
  else
      if [ -d "$tf_full_path" ]; then

          cd "$tf_full_path" || exit 1

          terraform plan -input=false -out "$tmp_plan/plan.tfplan"  || exit 1
          terraform show -json "$tmp_plan/plan.tfplan" > "$tmp_plan/plan.json" || exit 1

          gcloud beta terraform vet "$tmp_plan/plan.json" --policy-library="$policy_file_path" --project="$project" || exit 1

          cd "$base_dir" || exit
      else
        echo "ERROR:  $tf_full_path does not exist"
        exit 1
      fi
  fi
}


# Intended to allow a module to customize a particular check or behavior.  For
# example, the pubsub module runs "kitchen converge" twice instead of the
# default one time.
if [[ -e /workspace/test/task_helper_functions.sh ]]; then
  # shellcheck disable=SC1091 # (May not exist)
  source /workspace/test/task_helper_functions.sh
fi
