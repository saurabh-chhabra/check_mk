' -----------------------------------------------------------------------------
' Check_MK windows agent plugin to gather information from local MSSQL servers
'
' This plugin can be used to collect information of all running MSSQL server
' on the local system.
'
' The current implementation of the check uses the "trusted authentication"
' where no user/password needs to be created in the MSSQL server instance. It
' is only needed to grant the user as which the Check_MK windows agent service
' is running access to the MSSQL database.
'
' The following sources are asked:
' 1. WMI - to gather a list of local MSSQL-Server instances
' 2. MSSQL-Servers via ADO/sqloledb connection to gather infos these infos:
'      a) list and sizes of available databases
'      b) counters of the database instance
'
' This check has been developed with MSSQL Server 2008 R2. It should work with
' older versions starting from at least MSSQL Server 2005.
' -----------------------------------------------------------------------------

Option Explicit

Dim WMI, prop, instId, instVersion, instIds, instName

' Directory of all database instance names
Set instIds = CreateObject("Scripting.Dictionary")

' Loop all found local MSSQL server instances
Set WMI = GetObject("WINMGMTS:\\.\root\Microsoft\SqlServer\ComputerManagement10")
For Each prop In WMI.ExecQuery("SELECT * FROM SqlServiceAdvancedProperty WHERE " & _
                               "SQLServiceType = 1 AND PropertyName = 'VERSION'")
    
    instId      = prop.ServiceName
    instVersion = prop.PropertyStrValue
    
    WScript.echo "<<<mssql_versions>>>"
    WScript.echo instId & "  " & instVersion
    
    ' Now query the server instance for the databases
    ' Use name as key and always empty value for the moment
    instIds.add instId, ""
Next

Set WMI = nothing

Dim CONN, RS, hostname

hostname = WScript.CreateObject("WScript.Shell").ExpandEnvironmentStrings("%COMPUTERNAME%")

' Initialize connection objects
Set CONN = CreateObject("ADODB.Connection")
Set RS = CreateObject("ADODB.Recordset")
CONN.Provider = "sqloledb"
' Select a special DB
'CONN.Properties("Initial Catalog").Value = "test123"
' At this place one could implement to user other authentication mechanism
CONN.Properties("Integrated Security").Value = "SSPI"


' Loop all found server instances and connect to them
' In my tests only the connect using the "named instance" string worked
For Each instId In instIds.Keys
    instName = Split(instId, "$")(1)
    CONN.Properties("Data Source").Value = hostname & "\" & instName
    CONN.Open
    
    ' Get counter data for the whole instance
    RS.Open "SELECT counter_name, object_name, cntr_value FROM sys.dm_os_performance_counters " & _
            "WHERE object_name NOT LIKE '%Deprecated%'", CONN
    wscript.echo "<<<mssql_counters>>>"
    Dim objectName, counterName, value
    Do While NOT RS.Eof
        objectName  = Replace(Trim(RS("object_name")), " ", "_")
        counterName = Replace(Trim(RS("counter_name")), " ", "_")
        value       = Trim(RS("cntr_value"))
        wscript.echo objectName & " " & counterName & " " & value
        RS.MoveNext
    Loop
    RS.Close
    
    ' First only read all databases in this instance and save it to the db names dict
    RS.Open "EXEC sp_databases", CONN
    Dim x, dbName, dbNames
    Set dbNames = CreateObject("Scripting.Dictionary")
    Do While NOT RS.Eof
        dbName = RS("DATABASE_NAME")
        dbNames.add dbName, ""
       RS.MoveNext    
    Loop
    RS.Close
    
    ' Now gather the db size and unallocated space
    wscript.echo "<<<mssql_tablespaces>>>"
    Dim i, dbSize, unallocated, reserved, data, indexSize, unused
    For Each dbName in dbNames.Keys
        ' Switch to other database and then ask for stats
        RS.Open "USE " & dbName, CONN
        ' sp_spaceused is a stored procedure which returns two selects
        ' which need to be looped
        RS.Open "EXEC sp_spaceused", CONN
        i = 0
        Do Until RS Is Nothing
            Do While NOT RS.Eof
                'For Each x in RS.fields
                '    wscript.echo x.name & " " & x.value
                'Next
                If i = 0 Then
                    ' Size of the current database in megabytes. database_size includes both data and log files.
                    dbSize      = Trim(RS("database_size"))
                    ' Space in the database that has not been reserved for database objects.
                    unallocated = Trim(RS("unallocated space"))
                Elseif i = 1 Then
                    ' Total amount of space allocated by objects in the database.
                    reserved    = Trim(RS("reserved"))
                    ' Total amount of space used by data.
                    data        = Trim(RS("data"))
                    ' Total amount of space used by indexes.
                    indexSize   = Trim(RS("index_size"))
                    ' Total amount of space reserved for objects in the database, but not yet used.
                    unused      = Trim(RS("unused"))
                End If
                RS.MoveNext
            Loop
            Set RS = RS.NextRecordset
            i = i + 1
        Loop
        wscript.echo instId & " " & dbName & " " & dbSize & " " & unallocated & " " & reserved & " " & _
                     data & " " & indexSize & " " & unused
        Set RS = CreateObject("ADODB.Recordset")
    Next
    
    ' Loop all databases to get the date of the last backup. Only show databases
    ' which have at least one backup 
    Dim lastBackupDate
    wscript.echo "<<<mssql_backup>>>"
    For Each dbName in dbNames.Keys
        RS.open "SELECT DATEDIFF(s, '19700101', MAX(backup_finish_date)) AS last_backup_date " & _
                "FROM msdb.dbo.backupset " & _
                "WHERE database_name = '" & dbName & "'", CONN
        Do While Not RS.Eof
            lastBackupDate = Trim(RS("last_backup_date"))
            If lastBackupDate <> "" Then
                wscript.echo instId & " " & dbName  & " " & lastBackupDate
            End If
            RS.MoveNext
        Loop
        RS.Close
    Next
    
    CONN.Close
Next

Set RS = nothing
Set CONN = nothing