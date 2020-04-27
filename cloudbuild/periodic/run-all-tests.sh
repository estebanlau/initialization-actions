#!/bin/bash

set -uxo pipefail

TESTS_TO_RUN=(
	"//presto:test_presto"
    "//ranger:test_ranger"
    "//rapids:test_rapids"
    "//rstudio:test_rstudio"
    "//solr:test_solr"
    "//tez:test_tez"
    "//tony:test_tony"
) #":DataprocInitActionsTestSuite"

bazel test \
	--jobs=15 \
	--local_cpu_resources=15 \
	--local_ram_resources=$((15 * 1024)) \
	--action_env=INTERNAL_IP_SSH=true \
	--test_output=errors \
	--noshow_progress \
	--noshow_loading_progress \
	--test_arg="--image_version=${IMAGE_VERSION}" \
	"${TESTS_TO_RUN[@]}"

ls
ls bazel-init-actions -R
ls bazel-bin -R
ls bazel-out -R
ls bazel-testlogs -R

COMMIT=$(git rev-parse HEAD)

get_build_num() {
	build_num=$(($(gsutil cat gs://init-actions-github-tests/counter.txt)-1))
	echo $build_num
}

BUILD_NUM=$(get_build_num)

# Reads the test log of a given component
get_test_logs() {
	component=$1
	logs_filepath=$(readlink -f bazel-testlogs/${component}/test_${component}/shard_1_of_3/test.log)
	logs=$(cat $logs_filepath)
	echo $logs
}

get_test_xml() {
	component=$1
	xml_filepath=$(readlink -f bazel-testlogs/${component}/test_${component}/shard_1_of_3/test.xml)
    xml=$(cat $xml_filepath)
	echo $xml
}

create_finished_json() {
  component=$1
  echo $(get_test_xml $component) > test.xml
  failures_num=$(grep -oP '(?<=failures=")(\d)' "test.xml" | tr -d "'")
  errors_num=$(grep -oP '(?<=errors=")(\d)' "test.xml" | tr -d "'")
  failures=$(xmllint --xpath 'string(/testsuites/@failures)' parse-test.xml)
  errors=$(xmllint --xpath 'string(/testsuites/@errors)' parse-test.xml)
  if [ "$errors" == "0" ] && [ "$failures" == "0" ]; then
  	status="SUCCESS"
  else
  	status="FAILURE"
  fi
  jq -n \
  	--argjson timestamp $(date +%s) \
  	--arg result $status \
  	--arg component $component \
  	--arg version $IMAGE_VERSION \
  	--arg build_num $BUILD_NUM \
  	--arg build_id $BUILD_ID \
  	--arg commit $COMMIT \
  	'{"timestamp":$timestamp, "result":$result, "job_version":$commit, "metadata": {"component":$component, "version":$version, "build_num":$build_num, "build_id":$build_id}}' > finished.json
}

#"job-version":"e8dcf26a1666f990efb9125e0297ac26fef892f9"

shopt -s nullglob
COMPONENT_DIRS=(bazel-testlogs/*)
COMPONENT_DIRS=("${COMPONENT_DIRS[@]##*/}") # Get only the component name
for dir in "${COMPONENT_DIRS[@]}"; do
  # Create build-log.txt
  echo $(get_test_logs $dir) > build-log.txt

  # Create finished.json
  create_finished_json $dir

  # Upload to GCS
  gsutil cp finished.json gs://init-actions-github-tests/logs/init_actions_tests/${dir}/${BUILD_NUM}/finished.json
  gsutil cp build-log.txt gs://init-actions-github-tests/logs/init_actions_tests/${dir}/${BUILD_NUM}/build-log.txt
  gsutil cp test.xml gs://init-actions-github-tests/logs/init_actions_tests/${dir}/${BUILD_NUM}/test.xml
done