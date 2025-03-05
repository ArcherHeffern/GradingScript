# results.csv Output
student_id | notes | import errors | import warnings | compile errors (| test_name passed | test_name fail_reason )... 

# Test File format
See Test.java. Must accept destfile as input at argument 1 and write results in JSON format to destfile.

Results File: 
```json
[
    {
        "name": string, // Test name
        "pass": boolean,
        "reason": string, // Failure reason
    }
]
```