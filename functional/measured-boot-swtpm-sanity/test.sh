#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
. /usr/share/beakerlib/beakerlib.sh || exit 1

AGENT_ID="d432fbb3-d2f1-4a97-9ef7-75bd81c00000"

rlJournalStart

    rlPhaseStartSetup "Do the keylime setup"
        rlRun 'rlImport "./test-helpers"' || rlDie "cannot import keylime-tests/test-helpers library"
        rlAssertRpm keylime
        # if TPM emulator is not present, terminate
        if ! limeTPMEmulated; then
            rlDie "This test requires TPM emulator"
        fi
        # start tpm emulator
        rlRun "limeStartTPMEmulator"
        rlRun "limeWaitForTPMEmulator"
        # make sure tpm2-abrmd is running
        rlServiceStart tpm2-abrmd
        sleep 5

        # update config.py to use our fake  binary_bios_measurements
        # for the rust agent this is handled in the /setup/install_upstream_rust_keylime task
        CONFIG=$(limeGetKeylimeFilepath --install config.py)
        if [ -n "${CONFIG}" ]; then
            rlFileBackup ${CONFIG}
            rlRun "sed -i 's%^MEASUREDBOOT_ML =.*%MEASUREDBOOT_ML = \"/var/tmp/binary_bios_measurements\"%' ${CONFIG}"
        fi
        rlRun "cp binary_bios_measurements /var/tmp"
        rlFileBackup /etc/hosts  # always backup something just to make rlFileRestore succeed

        # start ima emulator
        rlRun "limeInstallIMAConfig"
        rlRun "limeStartIMAEmulator"

        # update /etc/keylime.conf
        limeBackupConfig
        rlRun "limeUpdateConf tenant require_ek_cert False"
        rlRun "limeUpdateConf verifier measured_boot_policy_name accept-all"
        rlRun "limeUpdateConf revocations enabled_revocation_notifications '[]'"
        rlRun "limeUpdateConf agent enable_revocation_notifications false"
        # start keylime_verifier
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartRegistrar"
        rlRun "limeWaitForRegistrar"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
        # create allowlist and excludelist
        limeCreateTestLists
    rlPhaseEnd

    rlPhaseStartTest "Try adding agent with PRC15 configured in tpm_policy"
        TPM_POLICY='{"15":["0000000000000000000000000000000000000000","0000000000000000000000000000000000000000000000000000000000000000","000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"]}'
        rlRun "echo '{}' > mb_refstate.txt"
        rlRun -s "keylime_tenant -u $AGENT_ID --verify --tpm_policy '${TPM_POLICY}' --allowlist allowlist.txt --exclude excludelist.txt -f excludelist.txt -c add --mb_refstate mb_refstate.txt" 1
        rlAssertGrep 'ERROR - WARNING: PCR 15 is specified in "tpm_policy", but will in fact be used by measured boot. Please remove it from policy' $rlRun_LOG
    rlPhaseEnd

    rlPhaseStartTest "Add agent with empty tpm_policy"
        rlRun -s "keylime_tenant -u $AGENT_ID --verify --tpm_policy '{}' --allowlist allowlist.txt --exclude excludelist.txt -f excludelist.txt -c add --mb_refstate mb_refstate.txt"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
        rlRun -s "keylime_tenant -c cvlist"
        rlAssertGrep "{'code': 200, 'status': 'Success', 'results': {'uuids':.*'$AGENT_ID'" $rlRun_LOG -E
    rlPhaseEnd

    rlPhaseStartTest "Configure verifier to use elchecking/example measured boot policy, restart and re-register agent"
        rlRun "keylime_tenant -u $AGENT_ID -c delete"
        rlRun "keylime_tenant -u $AGENT_ID -c regdelete"
        rlRun "limeStopAgent"
        rlRun "limeStopVerifier"
        sleep 5
        rlRun "limeUpdateConf verifier measured_boot_policy_name example"
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
    rlPhaseEnd

    rlPhaseStartTest "Add agent with tpm_policy generated by create_mb_refstate script and incorrect PCR banks"
        # use installed create_mb_refstate or copy one from keylime_sources or download it from upstream master branch
        if [ -f /usr/share/keylime/scripts/create_mb_refstate ]; then
            SCRIPT=/usr/share/keylime/scripts/create_mb_refstate
        else
            rlRun "limeCopyKeylimeFile --source scripts/create_mb_refstate && chmod a+x create_mb_refstate"
            SCRIPT="./create_mb_refstate"
        fi
        rlRun "$SCRIPT /var/tmp/binary_bios_measurements mb_refstate2.txt"
        #rlRun "tsseventextend -tpm -if /var/tmp/binary_bios_measurements"
        rlRun -s "keylime_tenant -u $AGENT_ID --verify --tpm_policy '{}' --allowlist allowlist.txt --exclude excludelist.txt -f excludelist.txt -c add --mb_refstate mb_refstate2.txt"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Tenant Quote Failed'"
        rlAssertGrep "keylime.tpm - ERROR - For PCR 0 and hash sha256 the boot event log has value '.*' but the agent returned '.*'" $(limeVerifierLogfile) -E
    rlPhaseEnd

    rlPhaseStartTest "Restart services and re-register agent"
        rlRun "keylime_tenant -u $AGENT_ID -c delete"
        rlRun "keylime_tenant -u $AGENT_ID -c regdelete"
        rlRun "limeStopAgent"
        rlRun "limeStopVerifier"
        sleep 5
        rlRun "limeStartVerifier"
        rlRun "limeWaitForVerifier"
        rlRun "limeStartAgent"
        rlRun "limeWaitForAgentRegistration ${AGENT_ID}"
    rlPhaseEnd

    rlPhaseStartTest "Add agent with tpm_policy generated by create_mb_refstate script and correct PCR banks"
        rlRun "TPM_INTERFACE_TYPE=socsim tsseventextend -tpm -if /var/tmp/binary_bios_measurements"
        rlRun -s "keylime_tenant -u $AGENT_ID --verify --tpm_policy '{}' --allowlist allowlist.txt --exclude excludelist.txt -f excludelist.txt -c add --mb_refstate mb_refstate2.txt"
        rlRun "limeWaitForAgentStatus $AGENT_ID 'Get Quote'"
    rlPhaseEnd

    rlPhaseStartCleanup "Do the keylime cleanup"
        rlRun "limeStopAgent"
        rlRun "limeStopRegistrar"
        rlRun "limeStopVerifier"
        rlRun "limeStopIMAEmulator"
        rlRun "limeStopTPMEmulator"
        rlServiceRestore tpm2-abrmd
        limeSubmitCommonLogs
        limeClearData
        limeRestoreConfig
        rlFileRestore
    rlPhaseEnd

rlJournalEnd
