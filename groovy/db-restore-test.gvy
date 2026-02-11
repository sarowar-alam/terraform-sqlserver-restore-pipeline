def DB_CHOICES = [
    'DB001.Global',
    'DB002.Global', 
    'DB003.Global'
    ]

pipeline {
    agent { label 'built-in' }
    parameters {
        choice(
            name: 'TERRAFORM_ACTION',
            choices: [
                'Create',
                'Delete' 
            ],
            description: 'Whether you want to create / delete the environment'
        )
        choice(
            name: 'DB_GLOBAL',
            choices: DB_CHOICES,  // Use the variable here
            description: 'Select YOUR DB Name'
        )       
    }
    environment {

        CHECK_MONDAY = false

        AWS_REGION = 'us-east-1'
        IS_CREATE = false
        IS_DELETE = false        
        TF_PATH="${WORKSPACE}/Automated-MS-SQL-Backup-Restore-Job/"
        TF_INSTANCE_IP=""

        ADD_TRUSTED_HOSTS = "Automated-MS-SQL-Backup-Restore-Job\\scripts\\add-trusted-host.ps1"
        REMOVE_TRUSTED_HOSTS = "Automated-MS-SQL-Backup-Restore-Job\\scripts\\remove-trusted-host.ps1"
        DOWNLOAD_DB_TRANSFER = "Automated-MS-SQL-Backup-Restore-Job\\scripts\\download-transfer-db.py"
        PASSWORD_FILE = "Automated-MS-SQL-Backup-Restore-Job\\password.txt"

        DOWNLOAD_DB_REMOTE_SERVER = "Automated-MS-SQL-Backup-Restore-Job/scripts/download-s3-backup-remote.ps1"
        
        RESTORE_DB_SQL_CMD = "Automated-MS-SQL-Backup-Restore-Job/scripts/restore-db-sqlcmd.ps1"
        EXECUTE_DB_SQL_CMD = "Automated-MS-SQL-Backup-Restore-Job/scripts/execute-query.ps1"
        EXECUTE_DB_SQL_CMD_PROD = "Automated-MS-SQL-Backup-Restore-Job/scripts/execute-query-prod.ps1"

        powershellScriptPath = "Automated-MS-SQL-Backup-Restore-Job/scripts/download-transfer-db.ps1"

        PROD_SQL_IP="192.168.1.5"

        SQL_QUERY_FILE = "Automated-MS-SQL-Backup-Restore-Job/scripts/sql-query.sql"

        SECURE_PASSWORD = ""

        SOURCE_ROLE_ARN = "arn:aws:iam::YOUR_ACCOUNT_ID:role/restore-rc-mainline"
        SOURCE_BUCKET = "YOUR_SOURCE_BUCKET_NAME"
        SOURCE_PREFIX = "YOUR_SOURCE_PREFIX/"
        DEST_ROLE_ARN = "arn:aws:iam::YOUR_TEST_ACCOUNT_ID:role/restore"
        DEST_BUCKET = "YOUR_DEST_BUCKET_NAME"
        DEST_PREFIX = "YOUR_DEST_PREFIX/"
        REMOTE_LOCAL_DIR = "C:\\YOUR_REMOTE-DIR\\"
        PYTHON = 'python'
    }
    stages {


        stage('CheckLastMonday') {
            steps {
                script {
                    // Capture the boolean output from PowerShell
                    def result = powershell(
                        returnStdout: true, 
                        script: '''
                            & "Automated-MS-SQL-Backup-Restore-Job/scripts/last-monday.ps1"
                        '''
                    ).trim()
                    echo "Captured Output: ${result}"
                    
                    if (result == "False") {
                        CHECK_MONDAY = false
                    } else {
                        CHECK_MONDAY = true
                    }
                    echo "Is last Monday: ${CHECK_MONDAY}"
                }
            }
        }

        stage('InitializeVariables') {
            steps {
                script {

                    IS_CREATE = params.TERRAFORM_ACTION == 'Create'
                    IS_DELETE = params.TERRAFORM_ACTION == 'Delete'
                    echo "Creation is: ${IS_CREATE} | Deletion is: ${IS_DELETE}"
                }
            }
        }

        stage('IdentifyTriggerSource') {
            steps {
                script {
                    def triggerCause = currentBuild.getBuildCauses()
                    def selectedDB = params.DB_GLOBAL
                    def triggeredBy = "Unknown"
                    
                    if (triggerCause.find { it._class.contains('TimerTriggerCause') }) {
                        def currentDateTime = new Date().format("yyyy-MM-dd HH:mm:ss")
                        echo "Build Trigger Type: SCHEDULED"
                        echo "Current Date Time: ${currentDateTime}"
                        
                        // Use the same variable here for random selection
                        selectedDB = DB_CHOICES[new Random().nextInt(DB_CHOICES.size())]
                        echo "Randomly selected DB: ${selectedDB}"
                        triggeredBy = "System Scheduler"
                    } else {
                        // Get user information when manually triggered
                        def userCause = triggerCause.find { it._class.contains('UserIdCause') }
                        if (userCause) {
                            triggeredBy = userCause.userName ?: userCause.userId ?: "Unknown User"
                        }
                        echo "Build Trigger Type: USER_TRIGGERED"
                        echo "Triggered By: ${triggeredBy}"
                    }
                    env.SELECTED_DB = selectedDB
                    env.TRIGGERED_BY = triggeredBy
                }
            }
        }

    stage('EC2Deploy'){
        when {
                expression { IS_CREATE && CHECK_MONDAY } // Proceed only if validity is less 
            }        
        steps{
            script{
                echo "Lets Build the Environment ! "
                dir("terraform"){
                    git (url: 'git@github.com:sarowar-alam/sarowar.git',branch: 'main',credentialsId: 'YOUR_CREDENTIALS_ID_HERE')
                    
                    // Terraform apply
                    powershell """
                        Write-Host "Working with path: ${env.TF_PATH}"
                        Set-Location "${TF_PATH}"
                        terraform init
                        terraform plan
                        terraform apply -auto-approve
                    """
                    
                    try {
                        // Get Terraform outputs as JSON
                        def tfOutput = powershell(returnStdout: true, script: """
                            Set-Location "${TF_PATH}"
                            terraform output -json
                        """).trim()
                        
                        // Parse the JSON
                        def tfJson = readJSON text: tfOutput
                        
                        // Validate and extract instance_public_ip
                        if (!tfJson || !tfJson.containsKey('instance_public_ip')) {
                            error("instance_public_ip not found in Terraform outputs. Available outputs: ${tfJson?.keySet()?.join(', ') ?: 'None'}")
                        }
                        
                        def instancePublicIp = tfJson.instance_public_ip.value
                        if (!instancePublicIp) {
                            error("instance_public_ip value is empty or null")
                        }
                        
                        echo "Captured instance public IP: ${instancePublicIp}"                        
                        // Read password file
                        def password = powershell(returnStdout: true, script: """
                            Set-Location "${TF_PATH}"
                            if (Test-Path password.txt) {
                                Get-Content password.txt -Raw
                            } else {
                                Write-Error "password.txt file not found in ${TF_PATH}"
                                exit 1
                            }
                        """).trim()

                        if (!password) {
                            error("Password file is empty or could not be read")
                        }

                        // Store variables
                        tfInstanceIp = instancePublicIp
                        env.TF_INSTANCE_IP = instancePublicIp
                        
                    } catch (Exception e) {
                        echo "ERROR during Terraform output processing: ${e.getMessage()}"
                        // Optional: Add terraform destroy on failure
                        powershell """
                            Set-Location "${TF_PATH}"
                            terraform plan
                        """
                        error("Failed to process Terraform outputs: ${e.getMessage()}")
                    }
                }
            }
        }
    }

    stage('Destroy'){
        when {
                expression { IS_DELETE } // Proceed only if validity is less 
            }        
        steps{
            script{
                echo "Lets Build the Environment ! "
                dir("terraform"){
                    git (url: 'git@github.com:sarowar-alam/sarowar.git',branch: 'main',credentialsId: 'YOUR_CREDENTIALS_ID_HERE')
                    
                    // Terraform apply
                    powershell """
                        Write-Host "Working with path: ${env.TF_PATH}"
                        Set-Location "${TF_PATH}"
                        terraform init
                        terraform destroy -auto-approve
                    """
                }
            }
        }
    }



    // In subsequent stages, you can access these variables
    stage('TerraformOutputs') {
        when {
                expression { IS_CREATE && CHECK_MONDAY } // Proceed only if validity is less 
            }         
        steps {
            script {
                echo "Using instance IP: ${tfInstanceIp}"
            }
        }
    }    

    stage('AddTrustedHosts') {
        when {
                expression { IS_CREATE && CHECK_MONDAY} // Proceed only if validity is less 
            }         
        steps {
            script {
                def targetIp = tfInstanceIp?.trim()
                if (!targetIp) {
                    error("IP address parameter is required")
                }
                
                try {
                    // Execute the PowerShell script
                    def result = bat(
                        script: """
                            aws sts get-caller-identity
                            whoami
                            powershell -ExecutionPolicy Bypass -File "${ADD_TRUSTED_HOSTS}" -IPAddress "${targetIp}"
                        """,
                        returnStatus: true,  // Return exit code instead of stdout
                        label: "Adding ${targetIp} to trusted hosts"
                    )
                    
                    
                    // Check the exit code
                    if (result != 0) {
                        error("Failed to add IP to trusted hosts. PowerShell script exited with code: ${result}")
                    }
                    
                    echo "Successfully added ${targetIp} to trusted hosts"
                    
                } catch (Exception e) {
                    echo "ERROR: Failed to execute trusted hosts script: ${e.getMessage()}"
                    echo "Target IP: ${targetIp}"
                    echo "Script path: ${ADD_TRUSTED_HOSTS}"
                    error("Trusted hosts operation failed")
                }
            }
        }
    }    


    stage('DownloadTransferDB') {
        when {
            expression { IS_CREATE && CHECK_MONDAY} // Proceed only if validity is less 
        }         
        steps {
            script {

                def targetIp = tfInstanceIp?.trim()
                if (!targetIp) {
                    error("IP address parameter is required")
                }
                def S3_PREFIX_SOURCE = "${SOURCE_PREFIX}${env.SELECTED_DB}"     
                // For shell commands, use single quotes to prevent interpretation
                
                def result = bat(
                    script: """
                    python "${DOWNLOAD_DB_TRANSFER}" --source-role-arn "${SOURCE_ROLE_ARN}" --source-bucket "${SOURCE_BUCKET}" --source-prefix "${S3_PREFIX_SOURCE}" --dest-role-arn "${DEST_ROLE_ARN}" --dest-bucket "${DEST_BUCKET}" --dest-prefix "${DEST_PREFIX}"
                    """,
                    returnStatus: true,
                    label: "Trasferring DB to ${targetIp}"
                )

                // Check the exit code
                if (result != 0) {
                    error("Failed to transfer DB with code ${result}")
                }                
                echo "Successfully transferred DB to ${targetIp}"                
            }
        }
        
        post {
            success {
                echo "Database transfer completed successfully!"
            }
            failure {
                echo "Database transfer failed!"
            }
        }
    }

    stage('DownloadDBRemote') {
        when {
            expression { IS_CREATE && CHECK_MONDAY }
        }         
        steps {
            script {
                def targetIp = tfInstanceIp?.trim()
                if (!targetIp) {
                    error("IP address parameter is required")
                }
                def DB_NAME = "${env.SELECTED_DB}"

                try {
                    echo "We are about to Download DB in ${targetIp}"
                    echo "Our DB Name ${DB_NAME}"
                    echo "Script will be Executed ${DOWNLOAD_DB_REMOTE_SERVER}"
                    def result = bat(
                        script: """
                            powershell -ExecutionPolicy Bypass -File "${DOWNLOAD_DB_REMOTE_SERVER}" -RemoteServer "${targetIp}" -Username "administrator" -S3BucketName "${DEST_BUCKET}" -S3Prefix "${DEST_PREFIX}" -DBName "${DB_NAME}" -RemoteDirectory "C:\\YOUR_REMOTE-DIR\\"
                        """,
                        returnStatus: true,  // Return exit code instead of stdout
                        label: "Downlaoding DB ${DB_NAME} in ${targetIp}"
                    )
                    // Check the exit code
                    if (result == 0) {
                        echo "Successfully Downloaded ${DB_NAME} in ${targetIp}"
                    } else {
                        error("Failed to download DB ${DB_NAME} in ${result}")
                    }
                                            

                } catch (Exception e) {
                    currentBuild.result = 'FAILURE'
                    error("Database Download failed: ${e.getMessage()}")
                }
            }
        }
    }



    stage('RestoreDatabase') {
        when {
                expression { IS_CREATE && CHECK_MONDAY} // Proceed only if validity is less 
            }         
        steps {
            script {
                def targetIp = tfInstanceIp?.trim()
                if (!targetIp) {
                    error("IP address parameter is required")
                }
                def DB_NAME = "${env.SELECTED_DB}"                     
                try {
                    def restore_db_with_sqlcmd = powershell(returnStatus: true, script: """
                        & '${RESTORE_DB_SQL_CMD}' -RemoteServerIP '${targetIp}' `
                                                -Username 'administrator' `
                                                -RemoteFolderPath 'C:\\YOUR_REMOTE-DIR' `
                                                -FilePrefix '${DB_NAME}' `
                                                -DatabaseName '${DB_NAME}'
                    """)
                    if (restore_db_with_sqlcmd != 0) {
                        error "PowerShell script failed with exit code: ${restore_db_with_sqlcmd}"
                    }
                } catch (Exception e) {
                    currentBuild.result = 'FAILURE'
                    error("Database restore failed: ${e.getMessage()}")
                }
            }
        }
    }


    stage('ExecuteQueryDatabase') {
        when {
                expression { IS_CREATE && CHECK_MONDAY } // Proceed only if validity is less 
            }         
        steps {
            script 
            {
                def targetIp = tfInstanceIp?.trim()
                if (!targetIp) {
                    error("IP address parameter is required")
                }
                echo "We got the Remote Server IP: ${targetIp}"
                def DB_NAME = "${env.SELECTED_DB}"         
                echo "Databse to Restore : ${DB_NAME}"
                
                try {

                    // Variables to capture results
                    def testResults = ""
                    def prodResults = ""                    
                    
                    def restore_db_with_sqlcmd = powershell(returnStdout: true, script: """
                        & '${EXECUTE_DB_SQL_CMD}' -RemoteServerIP '${targetIp}' `
                                                -Username 'administrator' `
                                                -RemoteFolderPath 'C:\\YOUR_REMOTE-DIR' `
                                                -SQLFilePath '${SQL_QUERY_FILE}' `
                                                -DatabaseName '${DB_NAME}'
                    """)

                    echo "Raw test output: ${restore_db_with_sqlcmd}"
                    
                    // Extract only the formatted table output from the PowerShell script
                    testResults = extractTableOutput(restore_db_with_sqlcmd, "Restore Test")
                    echo "Test Results captured: ${testResults}"
                    
                    if (restore_db_with_sqlcmd == null || restore_db_with_sqlcmd.isEmpty()) {
                        error "PowerShell script failed - no output returned"
                    }

                    withCredentials([[$class: 'UsernamePasswordMultiBinding', credentialsId: 'YOUR_CREDENTIALS_ID_HERE', 
                    usernameVariable: 'USERNAME', passwordVariable: 'PASSWORD']])
                    {
                        def restore_db_with_sqlcmd_prod = powershell(returnStdout: true, script: """
                            & '${EXECUTE_DB_SQL_CMD_PROD}' -RemoteServerIP '${PROD_SQL_IP}' `
                                                    -Username "${USERNAME}" `
                                                    -Password (ConvertTo-SecureString '${PASSWORD}' -AsPlainText -Force) `
                                                    -RemoteFolderPath 'C:\\YOUR_REMOTE-DIR' `
                                                    -SQLFilePath '${SQL_QUERY_FILE}' `
                                                    -DatabaseName '${DB_NAME}'
                        """)
                        
                        echo "Raw production output: ${restore_db_with_sqlcmd_prod}"
                        
                        // Extract only the formatted table output from the PowerShell script
                        prodResults = extractTableOutput(restore_db_with_sqlcmd_prod, "Production")
                        echo "Production Results captured: ${prodResults}"
                        
                        if (restore_db_with_sqlcmd_prod == null || restore_db_with_sqlcmd_prod.isEmpty()) {
                            error "Production PowerShell script failed - no output returned"
                        }    

                    }

                    // Send email with results
                    sendResultsEmail(testResults, prodResults)                    

                } catch (Exception e) {
                    currentBuild.result = 'FAILURE'
                    error("Database restore failed: ${e.getMessage()}")
                }
            }
        }
    }


    stage('RemoveTrustedHosts') {
        when {
                expression { IS_CREATE && CHECK_MONDAY} // Proceed only if validity is less 
            }         
        steps {
            script {
                def targetIp = tfInstanceIp?.trim()
                if (!targetIp) {
                    error("IP address parameter is required")
                }
                
                try {
                    // Execute the PowerShell script
                    def result = bat(
                        script: """
                            aws sts get-caller-identity
                            whoami
                            powershell -ExecutionPolicy Bypass -File "${REMOVE_TRUSTED_HOSTS}" -IPAddress "${targetIp}"
                        """,
                        returnStatus: true,  // Return exit code instead of stdout
                        label: "Removing ${targetIp} FROM trusted hosts"
                    )
                    
                    
                    // Check the exit code
                    if (result != 0) {
                        error("Failed to Remove IP from trusted hosts. PowerShell script exited with code: ${result}")
                    }
                    
                    echo "Successfully Removed ${targetIp} From trusted hosts"
                    
                } catch (Exception e) {
                    echo "ERROR: Failed to execute trusted hosts script: ${e.getMessage()}"
                    echo "Target IP: ${targetIp}"
                    echo "Script path: ${REMOVE_TRUSTED_HOSTS}"
                    error("Removing Trusted hosts operation failed")
                }
            }
        }
    }    


    stage('Destroy-Success'){
        when {
                expression { IS_CREATE && CHECK_MONDAY} // Proceed only if validity is less 
            } 
        steps{
            script{
                echo "Lets Destroy the Environment ! "
                dir("terraform"){
                    git (url: 'git@github.com:sarowar-alam/sarowar.git',branch: 'main',credentialsId: 'YOUR_CREDENTIALS_ID_HERE')
                    
                    // Terraform apply
                    powershell """
                        Write-Host "Working with path: ${env.TF_PATH}"
                        Set-Location "${TF_PATH}"
                        terraform init
                        terraform destroy -auto-approve
                    """
                }
            }
        }
    }



    }

    post {
    always {
        script {
            try {
                // Workspace cleanup
                if (fileExists(env.WORKSPACE)) {
                    echo "Cleaning up workspace: ${env.WORKSPACE}"
                    deleteDir()
                    cleanWs(
                        cleanWhenNotBuilt: false,
                        deleteDirs: true,
                        disableDeferredWipeout: true,
                        notFailBuild: true,
                        patterns: [
                            [pattern: '.gitignore', type: 'INCLUDE'],
                            [pattern: '.propsfile', type: 'EXCLUDE']
                        ]
                    )
                }
            } catch (Exception e) {
                echo "WARNING: Cleanup failed - ${e.message}"
            }
        }
    }

failure {
    script {
        try {
            withCredentials([[
                $class: 'UsernamePasswordMultiBinding',
                credentialsId: 'YOUR_CREDENTIALS_ID_HERE',
                usernameVariable: 'AWS_ACCESS_KEY_ID',
                passwordVariable: 'AWS_SECRET_ACCESS_KEY'
            ]]) {
                // Define recipients
                def toRecipients = "'YOUR_NAME@YOUR_DOMAIN.COM'"
                def ccRecipients = "'YOUR_NAME@YOUR_DOMAIN.COM'"
                
                // Get error message
                def errorMsg = currentBuild.rawBuild.getLog(100).findAll { 
                    it.contains('ERROR') || it.contains('FAIL') || it.contains('Exception') 
                }.join('\n')
                if (!errorMsg) {
                    errorMsg = "No specific error message captured (check build logs)"
                }

                // Create the properly indented Python script
                def pythonScript = """\
import boto3
import os

def send_email_SES():
    AWS_REGION = 'us-east-1'
    SENDER_EMAIL = 'DevOps_Jankins_Automation <noreply@YOUR_DOMAIN.COM>'
    TO_RECIPIENTS = [${toRecipients}]
    CC_RECIPIENTS = [${ccRecipients}]
    SUBJECT = 'FAILED: ${env.JOB_NAME.replace("'", "\\\\'")} #${env.BUILD_NUMBER}'
    ERROR_MESSAGE = '''${errorMsg.replace("'", "\\\\'")}'''
    
    session = boto3.Session(
        aws_access_key_id=os.environ['AWS_ACCESS_KEY_ID'],
        aws_secret_access_key=os.environ['AWS_SECRET_ACCESS_KEY']
    )
    ses_client = session.client('ses', region_name=AWS_REGION)
    
    try:
        response = ses_client.send_email(
            Destination={
                'ToAddresses': TO_RECIPIENTS,
                'CcAddresses': CC_RECIPIENTS
            },
            Message={
                'Body': {
                    'Html': {
                        'Charset': 'UTF-8',
                        'Data': f'''<html>
                            <body>
                                <h2>Build Failed</h2>
                                <p><strong>Job:</strong> ${env.JOB_NAME.replace("'", "\\\\'")}</p>
                                <p><strong>Build:</strong> #${env.BUILD_NUMBER}</p>
                                <p><strong>Console:</strong> <a href="${env.BUILD_URL}">${env.BUILD_URL}</a></p>
                                <hr>
                                <h3>Error Details:</h3>
                                <pre style="background:#f5f5f5;padding:10px;border-radius:5px;">{ERROR_MESSAGE}</pre>
                            </body>
                        </html>'''
                    }
                },
                'Subject': {
                    'Charset': 'UTF-8',
                    'Data': SUBJECT
                },
            },
            Source=SENDER_EMAIL,
        )
        print('Email sent! Message ID:', response['MessageId'])
    except Exception as e:
        print('Email sending failed:', str(e))
        raise

send_email_SES()
""".stripIndent()

                // Write and execute
                writeFile file: 'send_email_temp.py', text: pythonScript
                def output = bat(script: "python send_email_temp.py", returnStdout: true).trim()
                echo "Email sending output: ${output}"
                bat "del send_email_temp.py"
                
                if (output.contains("Email sending failed")) {
                    error("Failed to send notification email")
                }
            }
        } catch (Exception e) {
            echo "ERROR: Failed to send failure notification - ${e.message}"
        }
    }
}
} // End of Post Cleanup and Mail of Failure 


}

// Improved function to extract table output from PowerShell script results
def extractTableOutput(String powerShellOutput, String scriptType) {
    if (!powerShellOutput) return "No output captured"
    
    echo "=== Searching for table in ${scriptType} output ==="
    
    // Look for the formatted table section using more flexible pattern matching
    def lines = powerShellOutput.split('\r?\n')
    def tableLines = []
    def inTable = false
    def borderCount = 0
    
    for (line in lines) {
        def trimmedLine = line.trim()
        
        // Detect table borders - look for lines with multiple asterisks
        if (trimmedLine.contains('************') || trimmedLine.matches('^\\*+$')) {
            borderCount++
            inTable = !inTable
            echo "Border detected: ${trimmedLine} (borderCount: ${borderCount}, inTable: ${inTable})"
            continue
        }
        
        // If we're inside a table section and line has table content
        if (inTable && borderCount >= 1 && trimmedLine.startsWith('*') && trimmedLine.endsWith('*')) {
            // Clean the line by removing border characters and extra spaces
            def cleanLine = trimmedLine.replaceAll('^\\*\\s*', '').replaceAll('\\s*\\*$', '').trim()
            if (cleanLine && !cleanLine.contains('---') && !cleanLine.matches('^[-\\s]+$')) {
                tableLines.add(cleanLine)
                echo "Table line captured: ${cleanLine}"
            }
        }
    }
    
    echo "Total table lines captured: ${tableLines.size()}"
    
    if (tableLines.isEmpty()) {
        // Fallback: try to find any table-like data
        def fallbackLines = []
        lines.each { line ->
            def trimmedLine = line.trim()
            // Look for lines that contain pipe characters or look like table rows
            if (trimmedLine.contains('|') || 
                (trimmedLine.contains('TotalCount') && trimmedLine.contains('LastActivityId')) ||
                trimmedLine.matches('.*\\d+\\s+\\d+.*')) {
                fallbackLines.add(trimmedLine)
            }
        }
        
        if (!fallbackLines.isEmpty()) {
            return fallbackLines.join('<br>')
        }
        
        return "No table data found in output"
    }
    
    return tableLines.join('<br>')
}

// Alternative simpler extraction function if the above doesn't work
def extractTableOutputSimple(String powerShellOutput, String scriptType) {
    if (!powerShellOutput) return "No output captured"
    
    echo "=== Using simple extraction for ${scriptType} ==="
    
    def lines = powerShellOutput.split('\r?\n')
    def dataLines = []
    
    // Look for lines containing the data pattern (numbers separated by spaces)
    lines.each { line ->
        def trimmedLine = line.trim()
        // Match lines that contain two numbers separated by spaces (like "41596          70573")
        if (trimmedLine.matches('.*\\d+\\s+\\d+.*') && 
            !trimmedLine.contains('---') && 
            !trimmedLine.contains('TotalCount') &&
            !trimmedLine.matches('^[\\*\\-\\s]+$')) {
            dataLines.add(trimmedLine)
            echo "Data line found: ${trimmedLine}"
        }
    }
    
    if (dataLines.isEmpty()) {
        return "No data rows found in output"
    }
    
    return dataLines.join('<br>')
}

// Function to send email with results
def sendResultsEmail(String testResults, String prodResults) {
    withCredentials([[
        $class: 'UsernamePasswordMultiBinding',
        credentialsId: 'YOUR_CREDENTIALS_ID_HERE',
        usernameVariable: 'AWS_ACCESS_KEY_ID',
        passwordVariable: 'AWS_SECRET_ACCESS_KEY'
    ]]) {
        // Define recipients
        def toRecipients = "'YOUR_NAME@YOUR_DOMAIN.COM'"
        def ccRecipients = "'YOUR_NAME@YOUR_DOMAIN.COM'"
        
        // Parse the results into structured data
        def testTableData = parseTableData(testResults)
        def prodTableData = parseTableData(prodResults)
        
        // Create HTML table for results
        def htmlContent = """
        <html>
        <head>
            <style>
                body { font-family: WPP, sans-serif; margin: 20px; background-color: #f5f5f5; }
                .container { background-color: white; padding: 20px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
                .main-table { width: 100%; border-collapse: collapse; margin: 20px 0; }
                .main-table th, .main-table td { 
                    border: 1px solid #ddd; 
                    padding: 15px; 
                    text-align: center; 
                    vertical-align: top;
                }
                .main-table th { 
                    background-color: #2c3e50; 
                    color: white; 
                    font-weight: bold; 
                    font-size: 16px;
                }
                .test-column { background-color: #ecf0f1; }
                .prod-column { background-color: #f8f9fa; }
                .sub-table { 
                    width: 100%; 
                    border-collapse: collapse; 
                    margin: 10px 0;
                    font-family: 'Courier New', monospace;
                    font-size: 12px;
                }
                .sub-table th, .sub-table td { 
                    border: 1px solid #bdc3c7; 
                    padding: 8px 12px; 
                    text-align: center;
                }
                .sub-table th { 
                    background-color: #34495e; 
                    color: white; 
                    font-weight: bold;
                }
                .sub-table tr:nth-child(even) { background-color: #f2f2f2; }
                .sub-table tr:hover { background-color: #e3f2fd; }
                .header-row { background-color: #3498db; color: white; }
                .success-banner { 
                    background-color: #27ae60; 
                    color: white; 
                    padding: 15px; 
                    border-radius: 5px; 
                    margin: 10px 0;
                    text-align: center;
                }
                .timestamp { 
                    color: #7f8c8d; 
                    font-size: 12px; 
                    text-align: center; 
                    margin: 10px 0;
                }
                .no-data { 
                    color: #e74c3c; 
                    font-style: italic; 
                    text-align: center;
                    padding: 20px;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="success-banner">
                    <h2>✓ Database ${env.SELECTED_DB} Restore Test Completed Successfully</h2>
                </div>
                
                <div style="text-align: center; margin: 15px 0;">
                    <p>
                        Job: <strong>${env.JOB_NAME}</strong> | 
                        Triggered By: <strong>#${env.TRIGGERED_BY}</strong> | 
                        Build: <strong>#${env.BUILD_NUMBER}</strong> | 
                        URL: <a href="${env.BUILD_URL}"><strong>View Build</strong></a>
                    </p>
                </div>


                <table class="main-table">
                    <tr class="header-row">
                        <th width="50%">Query From Test Restore</th>
                        <th width="50%">Query From Production DB</th>
                    </tr>
                    <tr>
                        <td class="test-column">
                            ${testTableData.isEmpty() ? '<div class="no-data">No data available</div>' : createSubTable(testTableData, 'Test')}
                        </td>
                        <td class="prod-column">
                            ${prodTableData.isEmpty() ? '<div class="no-data">No data available</div>' : createSubTable(prodTableData, 'Production')}
                        </td>
                    </tr>
                </table>
                
                <div class="timestamp">
                    Generated on: ${new Date().format("yyyy-MM-dd HH:mm:ss")}
                </div>
            </div>
        </body>
        </html>
        """.stripIndent()

        // Create the Python script for sending email
        def pythonScript = """\
import boto3
import os

def send_email_SES():
    AWS_REGION = 'us-east-1'
    SENDER_EMAIL = 'DevOps_Automation DB Restore <noreply@YOUR_DOMAIN.COM>'
    TO_RECIPIENTS = [${toRecipients}]
    CC_RECIPIENTS = [${ccRecipients}]
    SUBJECT = 'Restore Test: Database ${env.SELECTED_DB} Triggered By: ${env.TRIGGERED_BY} | ${env.JOB_NAME.replace("'", "\\\\'")} #${env.BUILD_NUMBER}'
    
    HTML_CONTENT = '''${htmlContent.replace("'", "\\\\'")}'''
    
    session = boto3.Session(
        aws_access_key_id=os.environ['AWS_ACCESS_KEY_ID'],
        aws_secret_access_key=os.environ['AWS_SECRET_ACCESS_KEY']
    )
    ses_client = session.client('ses', region_name=AWS_REGION)
    
    try:
        response = ses_client.send_email(
            Destination={
                'ToAddresses': TO_RECIPIENTS,
                'CcAddresses': CC_RECIPIENTS
            },
            Message={
                'Body': {
                    'Html': {
                        'Charset': 'UTF-8',
                        'Data': HTML_CONTENT
                    }
                },
                'Subject': {
                    'Charset': 'UTF-8',
                    'Data': SUBJECT
                },
            },
            Source=SENDER_EMAIL,
        )
        print('Email sent successfully! Message ID:', response['MessageId'])
        return True
    except Exception as e:
        print('Email sending failed:', str(e))
        return False

if __name__ == "__main__":
    success = send_email_SES()
    exit(0 if success else 1)
""".stripIndent()

        // Write and execute the Python script
        writeFile file: 'send_results_email.py', text: pythonScript
        try {
            def output = bat(script: "python send_results_email.py", returnStdout: true).trim()
            echo "Email sending output: ${output}"
            
            if (output.contains("Email sending failed")) {
                echo "WARNING: Failed to send results email, but continuing pipeline"
            } else {
                echo "Results email sent successfully"
            }
        } catch (Exception e) {
            echo "WARNING: Failed to send email - ${e.message}, but continuing pipeline"
        } finally {
            bat "del send_results_email.py 2>nul || exit 0"
        }
    }
}

// Function to parse table data from the formatted string
def parseTableData(String tableOutput) {
    def rows = []
    
    if (!tableOutput || tableOutput == "No table data found") {
        return rows
    }
    
    // Split the output into lines
    def lines = tableOutput.split('<br>')
    
    // Look for data rows (lines containing numbers)
    lines.each { line ->
        def trimmedLine = line.trim()
        // Match lines with two numbers separated by spaces
        if (trimmedLine.matches('.*\\d+\\s+\\d+.*')) {
            // Extract numbers using regex
            def numbers = trimmedLine.replaceAll('[^\\d\\s]', '').trim().split('\\s+')
            if (numbers.size() >= 2) {
                rows.add([totalCount: numbers[0], lastActivityId: numbers[1]])
            }
        }
    }
    
    return rows
}

// Function to create HTML sub-table
def createSubTable(List tableData, String environment) {
    def html = """
    <div style="text-align: center; margin-bottom: 10px;">
        <strong>${environment} Environment</strong>
    </div>
    <table class="sub-table">
        <thead>
            <tr>
                <th>TotalCount</th>
                <th>LastActivityId</th>
            </tr>
        </thead>
        <tbody>
    """
    
    tableData.each { row ->
        html += """
            <tr>
                <td>${row.totalCount}</td>
                <td>${row.lastActivityId}</td>
            </tr>
        """
    }
    
    html += """
        </tbody>
    </table>
    <div style="text-align: center; margin-top: 10px; font-size: 11px; color: #666;">
        Total records: ${tableData.size()}
    </div>
    """
    
    return html
}