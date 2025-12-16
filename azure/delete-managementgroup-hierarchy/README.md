# Delete Management Group Hierarchy

This one came about because I'd created some automation for a Bicep module that handled deployment of management groups. A pipeline that tests this code used randomized names for management groups, so I wound up with a whole bunch of empty MGs that needed to be deleted.

This script takes in a management group by ID, does the queries required to find all its children, then deletes in reverse order (bottom up), so that you can clean up after yourself.