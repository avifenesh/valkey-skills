Hey, I've been going through the Valkey docs and I'm stuck on a few things. Some of these I half-know but I want to make sure I have the exact details right before I put them in our team wiki. Can you write up answers to all of these in `answers.md`? One section per question is fine.

## Q1: Slow command logging in Valkey 8.1+
What is the exact command to retrieve the last 10 slow-executing commands in Valkey 8.1+? Give the full command with all required arguments. What was this command called before Valkey 8.1, and why does the new command require an additional argument that the old one did not?

## Q2: Conditional SET based on current value
How do I atomically set the key `mykey` to `"new_value"` but only if its current value equals `"old_value"`? I need the exact command with all arguments. What version introduced this flag, and what two existing SET flags is it mutually exclusive with?

## Q3: Three COMMANDLOG entry types and their config directives
I know COMMANDLOG tracks three types of entries but I keep mixing them up. For each type, what is: (a) the exact type name used in the COMMANDLOG GET command, (b) the exact configuration directive that controls its threshold, and (c) the default threshold value with units?

## Q4: Setting a hash field with a TTL, only if it already exists
I need to set hash field `token` to value `abc123` on key `session:xyz` with a 300-second TTL, but ONLY if the field already exists. What is the exact command with all arguments and flags? What command is this, and what version introduced it?

## Q5: Lazyfree default values - Valkey vs Redis 7.x
In Valkey, what is the default value of `lazyfree-lazy-expire`? What was the default for this same parameter in Redis 7.x? Can you list all five lazyfree parameters and confirm whether each defaults to `yes` or `no` in current Valkey?

## Q6: Safe distributed lock release without Lua
How do I atomically delete the key `lock:order` only if its current value equals `token_abc` - without using a Lua script? What is this command called, what version introduced it, and what does it return on success vs failure (exact integer values)?

## Q7: RDB file format changes in Valkey 9.0
What RDB version number does Valkey 9.0 use? What magic string appears at the start of RDB files in this version, and how does it differ from all previous versions? What is the "foreign version" range and what is its purpose?

## Q8: Numbered databases in cluster mode
Before Valkey 9.0, what happened when you ran SELECT in cluster mode? What exact configuration directive enables multiple databases in cluster mode, and what is its default value? If you set it to 16, what databases become available?

## Q9: The deprecated io-threads companion directive
Older Redis guides say to set a companion directive alongside `io-threads`. What is the exact name of this deprecated directive? Why is it no longer needed in current Valkey? What other configuration directive is also deprecated because its behavior is now always enabled?

## Q10: HGETEX - get hash fields and set TTL atomically
How do I read hash fields `user_id` and `email` from key `session:abc` while simultaneously setting a 3600-second TTL on those fields? What is the exact command, what version introduced it, and how does it differ from a pipeline of HMGET + HEXPIRE?
