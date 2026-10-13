@{
    Severity     = @('Error', 'Warning')
    # The install script and workflow steps write progress for people and logs, not to the pipeline.
    ExcludeRules = @('PSAvoidUsingWriteHost')
}
