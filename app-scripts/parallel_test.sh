#!/bin/bash
echo > log/test.log
echo > tmp/failing_specs.log
echo > tmp/working_failing_specs.log

# Clear a variable that is often set in the session
unset QUICK
unset RUBY_DEBUG_OPEN

if [ ! "${USE_PG_HOST}" ] && [ "${NO_CLEAN_DB}" != 'true' ]; then
  echo "sudo is required to clean the database. Enter your password if prompted"
  sudo whoami
fi

# Ensure the tests run cleanly
export DISABLE_SPRING=1
bundle exec spring stop

# First, run brakeman
if [ "${NO_BRAKEMAN}" != 'true' ] && [ "${SKIP_BRAKEMAN}" != 'true' ]; then
  echo "Running brakeman"
  bin/brakeman -q --summary > /tmp/fphs-brakeman-summary.txt
  cat /tmp/fphs-brakeman-summary.txt
fi

echo "Setup filestore"
app-scripts/setup-dev-filestore.sh

if [ "${NO_CLEAN_DB}" != 'true' ]; then
  echo "Clean database"
  app-scripts/drop-test-db.sh
  app-scripts/create-test-db.sh
fi
reset

if [ "${SKIP_ZEITWERK}" != 'true' ]; then
  # Check zeitwerk before continuing
  bundle exec rails zeitwerk:check
  if [ $? != 0 ]; then
    echo "Zeitwerk test failed"
    exit 7
  fi

  export CI=true
fi

# Run the rspec tests in parallel. Use the first arg to define the path if needed
export PARALLEL_TEST_PROCESSORS=${PARALLEL_TEST_PROCESSORS:=$(nproc)}

# Clean up the temporary nfs_store directories
rm -rf /var/tmp/nfs_store_tmp*
rm -rf /var/tmp/nfs_store_test*

if [ -z "$@" ]; then
  specs='spec/models spec/controllers spec/features spec/r.*'
else
  specs="$@"
fi

start_date=$(date)

echo "========================================================================"
echo "Number of processes: ${PARALLEL_TEST_PROCESSORS}"
echo "Requested specs: ${specs}"
pwd
echo "========================================================================"

for spec in ${specs}; do
  echo "========================================================================"
  echo "==>>>> Running parallel specs for '${spec}'"
  echo "========================================================================"
  echo "========================================================================" >> tmp/working_failing_specs.log
  echo "==>>>> Running parallel specs for '${spec}'" >> tmp/working_failing_specs.log
  echo "==>>>> $(date)" >> tmp/working_failing_specs.log
  echo "========================================================================" >> tmp/working_failing_specs.log
  RAILS_ENV=test bundle exec rake parallel:spec["${spec}"] &
  while ! pgrep -f 'ruby bin/rspec' > /dev/null; do
    sleep 5
  done
  sleep 2
  # Display the running specs
  ps aux | grep 'ruby bin/rspec'

  # Wait for all specs to finish
  while pgrep -f 'ruby bin/rspec' > /dev/null; do
    sleep 5
  done
  # Kill the locked parent
  sleep 5
  if [ "$(pgrep -f 'bin/parallel_test')" ]; then
    kill $(pgrep -f 'bin/parallel_test')
  fi
  cat tmp/failing_specs.log >> tmp/working_failing_specs.log
done

echo "========================================================================" >> tmp/working_failing_specs.log
echo "All Done" >> tmp/working_failing_specs.log
echo "Runs with Failures: $(grep 'Failures: ' tmp/failing_specs.log | wc -l)" >> tmp/working_failing_specs.log
echo "==>>>> $(date)" >> tmp/working_failing_specs.log
echo "========================================================================" >> tmp/working_failing_specs.log
mv tmp/working_failing_specs.log tmp/failing_specs.log

echo "Started at  ${start_date}" >> tmp/failing_specs.log
echo "Finished at $(date)" >> tmp/failing_specs.log
