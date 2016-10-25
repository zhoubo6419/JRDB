//
//  FMDatabase+JRPersistentHandler.m
//  JRDB
//
//  Created by J on 2016/10/25.
//  Copyright © 2016年 Jrwong. All rights reserved.
//

#import "FMDatabase+JRPersistentHandler.h"
#import "JRQueueMgr.h"
#import "JRUtils.h"
#import "JRPersistent.h"
#import "JRFMDBResultSetHandler.h"
#import "NSObject+JRDB.h"
#import "JRMiddleTable.h"

#define AssertRegisteredClazz(clazz) NSAssert([clazz isRegistered], @"class: %@ should be registered in JRDBMgr", clazz)

@implementation FMDatabase (JRPersistentHandler)

#pragma mark - base operation

- (NSString *)handlerIdentifier {
    return self.databasePath;
}

- (void)jr_inQueue:(void (^)(id<JRPersistentHandler> _Nonnull))block {
    [[[JRQueueMgr shared] queueWithIdentifier:self.handlerIdentifier] addOperationWithBlock:^{
        block(self);
    }];
}

- (BOOL)jr_inTransaction:(void (^)(id<JRPersistentHandler> _Nonnull, BOOL * _Nonnull))block {
    BOOL rollback = ![self beginTransaction];
    if (rollback) {
        NSLog(@"begin transaction fail");
        return !rollback;
    }
    rollback = NO;
    block(self, &rollback);
    if (rollback) {
        NSLog(@"warning: execute error, database will roll back!!");
        [self rollback];
        return NO;
    } else {
        rollback = ![self commit];
    }
    return !rollback;
}

- (BOOL)jr_executeUseTransaction:(BOOL)useTransaction block:(BOOL (^)(id<JRPersistentHandler> _Nonnull))block {
    if (useTransaction) {
        if ([self inTransaction]) {
            NSLog(@"operation has open a transaction already, will not open again");
            return block(self);
        } else if (![self beginTransaction]) {
            NSLog(@"begin a transaction error");
            return NO;
        }
    }
    BOOL flag = block(self);
    if (useTransaction) {
        if (flag) {
            return [self commit];
        } else {
            [self rollback];
            return NO;
        }
    }
    return flag;
}

- (id)jr_executeSync:(BOOL)sync block:(id  _Nullable (^)(id<JRPersistentHandler> _Nonnull))block {
    NSOperationQueue *queue = [[JRQueueMgr shared] queueWithIdentifier:self.handlerIdentifier];
    BOOL flag = [queue isEqual:[NSOperationQueue currentQueue]];
    if (sync && !flag) {
        __block id result;
        [self jr_inQueue:^(id<JRPersistentHandler>  _Nonnull handler) {
            result = block(handler);
        }];
        return result;
    } else {
        return block(self);
    }
}

- (BOOL)jr_executeUpdate:(JRSql * _Nonnull)sql {
    return [self executeUpdate:sql.sqlString withArgumentsInArray:sql.args];
}

- (id _Nonnull)jr_executeQuery:(JRSql * _Nonnull)sql {
    return [self executeQuery:sql.sqlString withArgumentsInArray:sql.args];
}

#pragma mark - table operation


/**
 *  建表操作
 *
 *  @param clazz 对应表的类
 */
- (BOOL)jr_createTable4Clazz:(Class<JRPersistent> _Nonnull)clazz synchronized:(BOOL)synchronized {
    AssertRegisteredClazz(clazz);
    return [self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUpdate:[JRSqlGenerator createTableSql4Clazz:clazz table:nil]]);
    }];
}


/**
 *  把表删了，重新创建
 *
 *  @param clazz 类
 *
 *  @return 是否成功
 */
- (BOOL)jr_truncateTable4Clazz:(Class<JRPersistent> _Nonnull)clazz synchronized:(BOOL)synchronized {
    AssertRegisteredClazz(clazz);
    return [self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        BOOL flag = [handler jr_executeUpdate:[JRSqlGenerator dropTableSql4Clazz:clazz table:nil]];
        if (!flag) return @(flag);
        return @([handler jr_createTable4Clazz:clazz synchronized:synchronized]);
        
    }];
}


/**
 *  更新表操作
 *  (只会添加字段，不会删除和更改字段类型)
 *  @param clazz 对应表的类
 */
- (BOOL)jr_updateTable4Clazz:(Class<JRPersistent> _Nonnull)clazz synchronized:(BOOL)synchronized {
    AssertRegisteredClazz(clazz);
    return [self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        NSArray *sqls = [JRSqlGenerator updateTableSql4Clazz:clazz inDB:(FMDatabase *)handler table:nil];
        BOOL flag = YES;
        for (JRSql *sql in sqls) {
            flag = [handler jr_executeUpdate:sql];
            if (!flag) {
                break;
            }
        }
        return @(flag);
    }];
}

/**
 *  删除表
 *
 *  @param clazz 对应表的类
 */
- (BOOL)jr_dropTable4Clazz:(Class<JRPersistent> _Nonnull)clazz synchronized:(BOOL)synchronized {
    AssertRegisteredClazz(clazz);
    return [self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([self jr_executeUpdate:[JRSqlGenerator dropTableSql4Clazz:clazz table:nil]]);
    }];
}

/**
 *  检查对应类的表是否存在
 *
 *  @param clazz 类
 *
 *  @return 是否存在
 */
- (BOOL)jr_checkExistsTable4Clazz:(Class<JRPersistent> _Nonnull)clazz synchronized:(BOOL)synchronized {
    return [self tableExists:[clazz shortClazzName]];
}

#pragma mark - save


/**
 *  只保存one
 *
 *  @param one
 */
- (BOOL)jr_saveOne:(id<JRPersistent> _Nonnull)one useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized {
    AssertRegisteredClazz([one class]);
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            if (![handler jr_checkExistsTable4Clazz:[one class] synchronized:synchronized]) {
                BOOL result = [handler jr_createTable4Clazz:[one class] synchronized:synchronized];
                if (!result) {
                    NSLog(@"create table error");
                    return NO;
                }
            }
            
            if ([[one class] jr_customPrimarykey]) { // 自定义主键
                NSAssert([one jr_customPrimarykeyValue] != nil, @"custom Primary key should not be nil");
                long count = [handler jr_count4PrimaryKey:[one jr_customPrimarykeyValue] clazz:[one class] synchronized:synchronized];
                if (count) {
                    NSLog(@"warning: save error, primary key is exists");
                    return NO;
                }
            } else { // 默认主键
                NSAssert(one.ID == nil, @"The obj:%@ to be saved should not hold a ID", one);
            }
            
            JRSql *sql = [JRSqlGenerator sql4Insert:one toDB:(FMDatabase *)handler table:nil];
            [one setID:[JRUtils uuid]];
            [sql.args insertObject:one.ID atIndex:0];
            BOOL ret = [handler jr_executeUpdate:sql];
            
            if (ret) {
                // 保存完，执行block
                [one jr_executeFinishBlocks];
            }
            return ret;
            
        }]);
        
    }] boolValue];
}

/**
 *  保存数组
 *
 *  @param objects
 *  @param useTransaction 若外层有事务，请用NO，若没有，请用YES
 */
- (BOOL)jr_saveObjects:(NSArray<id<JRPersistent>> * _Nonnull)objects useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized {
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            __block BOOL needRollback = NO;
            [objects enumerateObjectsUsingBlock:^(id<JRPersistent>  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                needRollback = ![handler jr_saveOne:obj useTransaction:useTransaction synchronized:synchronized];
                *stop = needRollback;
            }];
            return !needRollback;
        }]);
    }] boolValue];
}


#pragma mark - update


/**
 *  更新one
 *
 *  @param one
 *  @param columns 需要更新的字段
 */
- (BOOL)jr_updateOne:(id<JRPersistent> _Nonnull)one columns:(NSArray<NSString *> * _Nullable)columns useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized {
    AssertRegisteredClazz([one class]);
    NSAssert([one jr_primaryKeyValue], @"The obj to be updated should hold a primary key");
    
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            // 表不存在
            if (![handler jr_checkExistsTable4Clazz:[one class] synchronized:synchronized]) {
                NSLog(@"table : %@ doesn't exists", [one class]);
                return NO;
            }
            
            
            id<JRPersistent> updateObj;
            
            if (columns.count) {
                
                NSObject<JRPersistent> *old = (NSObject<JRPersistent> *)
                [self jr_getByPrimaryKey:[one jr_primaryKeyValue] clazz:[one class] synchronized:synchronized];
                
                if (!old) {
                    NSLog(@"The object doesn't exists in database");
                    return NO;
                }
                for (NSString *name in columns) {
                    id value = [((NSObject *)one) valueForKey:name];
                    [((NSObject *)old) setValue:value forKey:name];
                }
                updateObj = old;
            } else {
                updateObj = one;
            }
            
            JRSql *sql = [JRSqlGenerator sql4Update:updateObj columns:columns toDB:self table:nil];
            [sql.args addObject:[updateObj jr_primaryKeyValue]];
            
            BOOL ret = [self jr_executeUpdate:sql];
            if (ret) {
                // 保存完，执行block
                if (ret) [one jr_executeFinishBlocks];
            }
            return ret;
        }]);
        
    }] boolValue];
}


/**
 *  更新array
 *
 *  @param objects
 *  @param columns 需要更新的字段
 *  @param useTransaction 若外层有事务，请用NO，若没有，请用YES
 */
- (BOOL)jr_updateObjects:(NSArray<id<JRPersistent>> * _Nonnull)objects columns:(NSArray<NSString *> * _Nullable)columns useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized {
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            __block BOOL needRollback;
            [objects enumerateObjectsUsingBlock:^(id<JRPersistent>  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                needRollback = ![handler jr_updateOne:obj columns:columns useTransaction:useTransaction synchronized:synchronized];
                *stop = needRollback;
            }];
            return !needRollback;
        }]);
    }] boolValue];
}

#pragma mark - delete


/**
 *  删除one，可选择自带事务或者自行在外层包裹事务
 *
 *  @param one
 *  @param useTransaction 若外层有事务，请用NO，若没有，请用YES
 */
- (BOOL)jr_deleteOne:(id<JRPersistent> _Nonnull)one useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized{
    
    AssertRegisteredClazz([one class]);
    NSAssert([one jr_primaryKeyValue], @"primary key should not be nil");
    
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            if (![handler jr_checkExistsTable4Clazz:[one class] synchronized:synchronized]) {
                NSLog(@"table : %@ doesn't exists", [one class]);
                return NO;
            }
            
            JRSql *sql = [JRSqlGenerator sql4Delete:one table:nil];
            [sql.args addObject:[one jr_primaryKeyValue]];
            BOOL ret = [handler jr_executeUpdate:sql];
            if (ret) {
                // 保存完，执行block
                [one jr_executeFinishBlocks];
            }
            return ret;
        }]);
    }] boolValue];

}


/**
 *  删除array，可选择自带事务或者自行在外层包裹事务
 *
 *  @param objects
 *  @param useTransaction 若外层有事务，请用NO，若没有，请用YES
 */
- (BOOL)jr_deleteObjects:(NSArray<id<JRPersistent>> * _Nonnull)objects useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized {
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            __block BOOL needRollback;
            [objects enumerateObjectsUsingBlock:^(id<JRPersistent>  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                needRollback = ![handler jr_deleteOne:obj useTransaction:useTransaction synchronized:synchronized];
                *stop = needRollback;
            }];
            return !needRollback;
        }]);
    }] boolValue];
}

#pragma mark - delete all

- (BOOL)jr_deleteAll:(Class<JRPersistent> _Nonnull)clazz useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized {
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            JRSql *sql = [JRSqlGenerator sql4DeleteAll:clazz table:nil];
            return [handler jr_executeUpdate:sql];
        }]);
    }] boolValue];
}

#pragma mark - save or update

- (BOOL)jr_saveOrUpdateOne:(id<JRPersistent> _Nonnull)one useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized {
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            BOOL isSave = YES;
            if ([[one class] jr_customPrimarykey]) { // 自定义主键
                NSAssert([one jr_customPrimarykeyValue] != nil, @"custom Primary key should not be nil");
                isSave = ![self jr_count4PrimaryKey:[one jr_customPrimarykeyValue] clazz:[one class] synchronized:NO];
            } else { // 默认主键
                isSave = !one.ID;
            }
            
            if (isSave) {
                return [self jr_saveOne:one useTransaction:NO synchronized:NO];
            } else {
                return [self jr_updateOne:one columns:nil useTransaction:NO synchronized:NO];
            }

        }]);
    }] boolValue];
}

- (BOOL)jr_saveOrUpdateObjects:(NSArray<id<JRPersistent>> * _Nonnull)objects useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized {
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            __block BOOL needRollback;
            [objects enumerateObjectsUsingBlock:^(id<JRPersistent>  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                needRollback = ![handler jr_deleteOne:obj useTransaction:useTransaction synchronized:synchronized];
                *stop = needRollback;
            }];
            return !needRollback;
        }]);
    }] boolValue];
}

#pragma mark - query

- (NSArray<id<JRPersistent>> * _Nonnull)jr_getByJRSql:(JRSql * _Nonnull)sql sync:(BOOL)sync resultClazz:(Class<JRPersistent> _Nonnull)clazz columns:(NSArray * _Nullable)columns {
    return [self jr_executeSync:sync block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        FMResultSet *restultSet = [handler jr_executeQuery:sql];
        NSArray *array = [JRFMDBResultSetHandler handleResultSet:restultSet forClazz:clazz columns:columns];
        return [array copy];
    }];
}

- (id<JRPersistent> _Nullable)jr_getByPrimaryKey:(id _Nonnull)primaryKey clazz:(Class<JRPersistent> _Nonnull)clazz synchronized:(BOOL)synchronized {
    AssertRegisteredClazz(clazz);
    NSAssert(primaryKey, @"id should be nil");
    JRSql *sql = [JRSqlGenerator sql4GetByPrimaryKeyWithClazz:clazz primaryKey:primaryKey table:nil];
    return [[self jr_getByJRSql:sql sync:synchronized resultClazz:clazz columns:nil] firstObject];
}

- (id<JRPersistent> _Nullable)jr_getByID:(NSString * _Nonnull)ID clazz:(Class<JRPersistent> _Nonnull)clazz synchronized:(BOOL)synchronized {
    AssertRegisteredClazz(clazz);
    NSAssert(ID, @"id should not be nil");
    return [self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        JRSql *sql = [JRSqlGenerator sql4GetByIDWithClazz:clazz ID:ID table:nil];
        return [[handler jr_getByJRSql:sql sync:synchronized resultClazz:clazz columns:nil] firstObject];
    }];
    
}

#pragma mark - convenience method

- (long)jr_count4PrimaryKey:(id)pk clazz:(Class<JRPersistent>)clazz synchronized:(BOOL)synchronized {
    AssertRegisteredClazz(clazz);
    NSAssert(pk, @"primary key should not be nil");
    FMResultSet *ret = [self jr_executeQuery:[JRSqlGenerator sql4CountByPrimaryKey:pk clazz:clazz table:nil]];
    while ([ret next]) {
        long count = [ret longForColumnIndex:0];
        [ret close];
        return count;
    }
    return 0;
}

@end

#pragma mark - 关联操作

@implementation FMDatabase (JRPersistentHandlerRecurively)

#pragma mark - link operation method
- (BOOL)jr_handleSave:(id<JRPersistent>)obj stack:(NSMutableArray<id<JRPersistent>> **)stack needRollBack:(BOOL *)needRollBack {
    
    if (*needRollBack) {
        return NO;
    }
    
    [[[obj class] jr_singleLinkedPropertyNames] enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, Class<JRPersistent>  _Nonnull clazz, BOOL * _Nonnull stop) {
        
        id value = [((NSObject *)obj) valueForKey:key];
        if (value) {
            NSString *identifier = [JRUtils uuid];
            if ([*stack containsObject:value]) {
                [value jr_addDidFinishBlock:^(id<JRPersistent>  _Nonnull object) {
                    [object jr_removeDidFinishBlockForIdentifier:identifier];
                    [self jr_updateOne:obj columns:@[key] useTransaction:NO synchronized:NO];
                } forIdentifier:identifier];
            } else {
                if (![*stack containsObject:obj]) {
                    [*stack addObject:obj];
                }
                [obj jr_addDidFinishBlock:^(id<JRPersistent>  _Nonnull object) {
                    [object jr_removeDidFinishBlockForIdentifier:identifier];
                    [*stack removeObject:object];
                } forIdentifier:identifier];
                [self jr_handleSave:value stack:stack needRollBack:needRollBack];
            }
        }
    }];
    
    NSString *tableName = [[obj class] shortClazzName];
    if (![self tableExists:tableName]) {
        if(![self jr_createTable4Clazz:[obj class] synchronized:NO]) {
            NSLog(@"create table: %@ error", tableName);
            *needRollBack = YES;
            return NO;
        }
    }
    
    
    id<JRPersistent> old;
    if ([obj jr_primaryKeyValue]) {
        old = [self jr_getByPrimaryKey:[obj jr_primaryKeyValue] clazz:[obj class] synchronized:NO];
    }
    
    if (!old) {
        BOOL ret = [self jr_saveOne:obj useTransaction:NO synchronized:NO];
        *needRollBack = !ret;
        if (!ret) {
            NSLog(@"save obj: %@ error, transaction will be rollback", obj);
        }
        return ret;
    } else {
        NSLog(@"obj for primary key : %@ ,has been exisist, can not be saved", [old jr_primaryKeyValue]);
        [obj setID:[old ID]];
        // 子对象已经存在不用保存，直接返回，若需要更新，需要自行手动更新
        return YES;
    }
    
}

- (BOOL)jr_handleOneToManySaveWithObj:(id<JRPersistent>)obj columns:(NSArray *)columns {
    NSAssert([self inTransaction], @"should in transaction");
    
    __block BOOL needRollBack = NO;
    // 监测一对多的保存
    [[[obj class] jr_oneToManyLinkedPropertyNames] enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, Class<JRPersistent>  _Nonnull clazz, BOOL * _Nonnull stop) {
        
        if (!(!columns || [columns containsObject:key])) { return; }
        
        NSArray *array = [((NSObject *)obj) valueForKey:key];
        // 逐个保存
        [array enumerateObjectsUsingBlock:^(NSObject<JRPersistent> * _Nonnull subObj, NSUInteger idx, BOOL * _Nonnull stop) {
            if (![subObj ID]) {
                // 设置父ID
                if ([obj class] == clazz) {
                    [subObj jr_setParentLinkID:[obj ID] forKey:key];
                }
                needRollBack = ![self jr_saveOneRecursively:subObj useTransaction:NO synchronized:NO];
                *stop = needRollBack;
            }
        }];
        
        if ([obj class] != clazz) {// 如果是同一张表则不需要中间表，是父子关系
            // 保存中建表
            JRMiddleTable *mid = [JRMiddleTable table4Clazz:clazz andClazz:[obj class] db:self];
            needRollBack = ![mid saveObjs:array forObj:obj];
        }
        *stop = needRollBack;
    }];
    return !needRollBack;
}


- (id<JRPersistent>)jr_objInStack:(NSArray *)array withID:(NSString *)ID {
    __block id<JRPersistent> obj = nil;
    [array enumerateObjectsUsingBlock:^(id<JRPersistent>  _Nonnull stackObj, NSUInteger idx, BOOL * _Nonnull stop) {
        if ([ID isEqualToString:[stackObj ID]]) {
            obj = stackObj;
            *stop = YES;
        }
    }];
    return obj;
}

- (id<JRPersistent>)jr_handleSingleLinkFindByID:(NSString *)ID clazz:(Class<JRPersistent>)clazz stack:(NSMutableArray<id<JRPersistent>> **)stack{
    id obj = [self jr_getByID:ID clazz:clazz synchronized:NO];
    [[clazz jr_singleLinkedPropertyNames] enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, Class<JRPersistent>  _Nonnull subClazz, BOOL * _Nonnull stop) {
        NSString *subID = [((NSObject *)obj) jr_singleLinkIDforKey:key];
        if (subID) {
            [(*stack) addObject:obj];
            id<JRPersistent> exists = [self jr_objInStack:(*stack) withID:subID];
            if (!exists) {
                exists = [self jr_handleSingleLinkFindByID:subID clazz:subClazz stack:stack];
            }
            [obj setValue:exists forKey:key];
        }
    }];
    return obj;
}

#pragma mark - save

/**
 *  关联保存保存one
 *
 *  @param one
 */
- (BOOL)jr_saveOneRecursively:(id<JRPersistent> _Nonnull)one useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized {
    
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            
            NSMutableArray *stack = [NSMutableArray array];
            __block BOOL needRollBack = NO;
            [((FMDatabase *)handler) jr_handleSave:one stack:&stack needRollBack:&needRollBack];
            
            if (!needRollBack) {
                // 监测一对多的保存 此时的 [one ID] 为 nil
                needRollBack = ![((FMDatabase *)handler) jr_handleOneToManySaveWithObj:one columns:nil];
            }
            return !needRollBack;
        }]);
    }] boolValue];
}

/**
 *  保存数组
 *
 *  @param objects
 *  @param useTransaction 若外层有事务，请用NO，若没有，请用YES
 */
- (BOOL)jr_saveObjectsRecursively:(NSArray<id<JRPersistent>> * _Nonnull)objects useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized {
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            __block BOOL needRollback;
            [objects enumerateObjectsUsingBlock:^(id<JRPersistent>  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                needRollback = ![((FMDatabase *)handler) jr_saveOneRecursively:obj useTransaction:useTransaction synchronized:synchronized];
                *stop = needRollback;
            }];
            return !needRollback;
        }]);
    }] boolValue];
}

#pragma mark - update


/**
 *  更新one
 *
 *  @param one
 *  @param columns 需要更新的字段
 */
- (BOOL)jr_updateOneRecursively:(id<JRPersistent> _Nonnull)one columns:(NSArray<NSString *> * _Nullable)columns useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized {
    
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            __block BOOL needRollBack = ![self jr_deleteOne:one useTransaction:NO synchronized:NO];
            if (!needRollBack) {
                // 监测一对多的 中间表 删除
                [[[one class] jr_oneToManyLinkedPropertyNames] enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, Class<JRPersistent>  _Nonnull clazz, BOOL * _Nonnull stop) {
                    
                    if ([one class] == clazz) {// 同类父子关系
                        NSString *condition = [NSString stringWithFormat:@"%@ = ?", ParentLinkColumn(key)];
                        JRSql *sql = [JRSqlGenerator sql4GetColumns:nil
                                                       byConditions:@[
                                                                      [JRQueryCondition condition:condition args:@[[one ID]] type:JRQueryConditionTypeAnd]
                                                                      ]
                                                              clazz:clazz
                                                            groupBy:nil
                                                            orderBy:nil
                                                              limit:nil
                                                             isDesc:NO
                                                              table:nil];
                        NSArray *children = [((FMDatabase *)handler) jr_findByJRSql:sql sync:synchronized resultClazz:clazz columns:nil];
                        needRollBack = ![self jr_deleteObjectsRecursively:children useTransaction:NO synchronized:synchronized];
                    } else {
                        JRMiddleTable *mid = [JRMiddleTable table4Clazz:clazz andClazz:[one class] db:self];
                        needRollBack = ![mid deleteID:[one ID] forClazz:[one class]];
                    }
                    *stop = needRollBack;
                }];
            }
            return !needRollBack;
        }]);
    }] boolValue];
}


/**
 *  更新array
 *
 *  @param objects
 *  @param columns 需要更新的字段
 *  @param useTransaction 若外层有事务，请用NO，若没有，请用YES
 */
- (BOOL)jr_updateObjectsRecursively:(NSArray<id<JRPersistent>> * _Nonnull)objects columns:(NSArray<NSString *> * _Nullable)columns useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized {
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            __block BOOL needRollback;
            [objects enumerateObjectsUsingBlock:^(id<JRPersistent>  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                needRollback = ![((FMDatabase *)handler) jr_updateOneRecursively:obj columns:columns useTransaction:useTransaction synchronized:synchronized];
                *stop = needRollback;
            }];
            return !needRollback;
        }]);
    }] boolValue];
}


#pragma mark - delete

/**
 *  删除one，可选择自带事务或者自行在外层包裹事务
 *
 *  @param one
 *  @param useTransaction 若外层有事务，请用NO，若没有，请用YES
 */
- (BOOL)jr_deleteOneRecursively:(id<JRPersistent> _Nonnull)one useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized{
    
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            __block BOOL needRollBack = ![self jr_deleteOne:one useTransaction:NO synchronized:NO];
            if (!needRollBack) {
                // 监测一对多的 中间表 删除
                [[[one class] jr_oneToManyLinkedPropertyNames] enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, Class<JRPersistent>  _Nonnull clazz, BOOL * _Nonnull stop) {
                    
                    if ([one class] == clazz) {// 同类父子关系
                        NSString *condition = [NSString stringWithFormat:@"%@ = ?", ParentLinkColumn(key)];
                        JRSql *sql = [JRSqlGenerator sql4GetColumns:nil
                                                       byConditions:@[
                                                                      [JRQueryCondition condition:condition args:@[[one ID]] type:JRQueryConditionTypeAnd]
                                                                      ]
                                                              clazz:clazz
                                                            groupBy:nil
                                                            orderBy:nil
                                                              limit:nil
                                                             isDesc:NO
                                                              table:nil];
                        NSArray *children = [self jr_findByJRSql:sql sync:synchronized resultClazz:clazz columns:nil];
                        needRollBack = ![self jr_deleteObjectsRecursively:children useTransaction:NO synchronized:synchronized];
                    } else {
                        JRMiddleTable *mid = [JRMiddleTable table4Clazz:clazz andClazz:[one class] db:self];
                        needRollBack = ![mid deleteID:[one ID] forClazz:[one class]];
                    }
                    *stop = needRollBack;
                }];
            }
            return !needRollBack;
        }]);
    }] boolValue];
}


/**
 *  删除array，可选择自带事务或者自行在外层包裹事务
 *
 *  @param objects
 *  @param useTransaction 若外层有事务，请用NO，若没有，请用YES
 */
- (BOOL)jr_deleteObjectsRecursively:(NSArray<id<JRPersistent>> * _Nonnull)objects useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized {
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            __block BOOL needRollback;
            [objects enumerateObjectsUsingBlock:^(id<JRPersistent>  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                needRollback = ![((FMDatabase *)handler) jr_deleteOneRecursively:obj useTransaction:useTransaction synchronized:synchronized];
                *stop = needRollback;
            }];
            return !needRollback;
        }]);
    }] boolValue];
}


#pragma mark - delete all

- (BOOL)jr_deleteAllRecursively:(Class<JRPersistent> _Nonnull)clazz useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized {
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            JRSql *sql = [JRSqlGenerator sql4GetColumns:nil byConditions:nil clazz:clazz groupBy:nil orderBy:nil limit:nil isDesc:NO table:nil];
            NSArray *array = [((FMDatabase *)handler) jr_getByJRSql:sql sync:synchronized resultClazz:clazz columns:nil];
            return [((FMDatabase *)handler) jr_deleteObjectsRecursively:array useTransaction:useTransaction synchronized:synchronized];
        }]);
    }] boolValue];
}

#pragma mark - save or update

- (BOOL)jr_saveOrUpdateOneRecursively:(id<JRPersistent> _Nonnull)one useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized {
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            BOOL isSave = YES;
            if ([[one class] jr_customPrimarykey]) { // 自定义主键
                NSAssert([one jr_customPrimarykeyValue] != nil, @"custom Primary key should not be nil");
                isSave = ![self jr_count4PrimaryKey:[one jr_customPrimarykeyValue] clazz:[one class] synchronized:NO];
            } else { // 默认主键
                isSave = !one.ID;
            }
            if (isSave) {
                return [self jr_saveOneRecursively:one useTransaction:useTransaction synchronized:NO];
            } else {
                return [self jr_updateOneRecursively:one columns:nil useTransaction:useTransaction synchronized:NO];
            }
        }]);
    }] boolValue];
}

- (BOOL)jr_saveOrUpdateObjectsRecursively:(NSArray<id<JRPersistent>> * _Nonnull)objects useTransaction:(BOOL)useTransaction synchronized:(BOOL)synchronized {
    return [[self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        return @([handler jr_executeUseTransaction:useTransaction block:^BOOL(id<JRPersistentHandler>  _Nonnull handler) {
            __block BOOL needRollback;
            [objects enumerateObjectsUsingBlock:^(id<JRPersistent>  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                needRollback = ![((FMDatabase *)handler) jr_saveOrUpdateOneRecursively:obj useTransaction:useTransaction synchronized:synchronized];
                *stop = needRollback;
            }];
            return !needRollback;
        }]);
    }] boolValue];
}

#pragma mark - query

- (NSArray<id<JRPersistent>> * _Nonnull)jr_findByJRSql:(JRSql * _Nonnull)sql sync:(BOOL)sync resultClazz:(Class<JRPersistent> _Nonnull)clazz columns:(NSArray * _Nullable)columns {
    
    return [self jr_executeSync:sync block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        
        NSArray *array = [handler jr_getByJRSql:sql sync:sync resultClazz:clazz columns:columns];
        
        if (!columns.count) {
            NSMutableArray *arr = [NSMutableArray array];
            [array enumerateObjectsUsingBlock:^(id  _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                [arr addObject:[((FMDatabase *)handler) jr_findByID:[obj ID] clazz:clazz synchronized:NO]];
            }];
            array = [arr copy];
        }
        return array;
    }];
    
}

- (id<JRPersistent> _Nullable)jr_findByPrimaryKey:(id _Nonnull)primaryKey clazz:(Class<JRPersistent> _Nonnull)clazz synchronized:(BOOL)synchronized {
    return [self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        if (![self jr_checkExistsTable4Clazz:clazz synchronized:synchronized]) {
            NSLog(@"table %@ doesn't exists", clazz);
            return nil;
        }
        NSObject<JRPersistent> *obj = [self jr_getByPrimaryKey:primaryKey clazz:clazz synchronized:synchronized];
        return [self jr_findByID:[obj ID] clazz:[obj class] synchronized:synchronized];
    }];
}

- (id<JRPersistent>)jr_findByID:(NSString *)ID clazz:(Class<JRPersistent>)clazz synchronized:(BOOL)synchronized {
    return [self jr_executeSync:synchronized block:^id _Nullable(id<JRPersistentHandler>  _Nonnull handler) {
        
        NSMutableArray *array = [NSMutableArray array];
        NSObject<JRPersistent> *obj = [((FMDatabase *)handler) jr_handleSingleLinkFindByID:ID clazz:clazz stack:&array];
        
        // 检查有无查询一对多
        [[[obj class] jr_oneToManyLinkedPropertyNames] enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, Class<JRPersistent>  _Nonnull clazz, BOOL * _Nonnull stop) {
            
            NSMutableArray *subList = [NSMutableArray array];
            if ([obj class] == clazz) { // 父子关系 同个类
                NSString *condition = [NSString stringWithFormat:@"%@ = ?", ParentLinkColumn(key)];
                JRSql *sql = [JRSqlGenerator sql4GetColumns:nil
                                               byConditions:@[
                                                              [JRQueryCondition condition:condition args:@[[obj ID]] type:JRQueryConditionTypeAnd],
                                                              ]
                                                      clazz:clazz
                                                    groupBy:nil
                                                    orderBy:nil
                                                      limit:nil
                                                     isDesc:NO
                                                      table:nil];
                NSArray *array = [((FMDatabase *)handler) jr_findByJRSql:sql sync:synchronized resultClazz:clazz columns:nil];
                [subList addObjectsFromArray:array];
            } else {
                JRMiddleTable *mid = [JRMiddleTable table4Clazz:clazz andClazz:[obj class] db:self];
                NSArray *ids = [mid anotherClazzIDsWithID:[obj ID] clazz:[obj class]];
                
                [ids enumerateObjectsUsingBlock:^(id  _Nonnull aID, NSUInteger idx, BOOL * _Nonnull stop) {
                    id sub = [self jr_findByID:aID clazz:clazz synchronized:synchronized];
                    if (sub) {
                        [subList addObject:sub];
                    }
                }];
            }
            [obj setValue:subList forKey:key];
            
        }];
        
        return obj;

    }];
}

@end


