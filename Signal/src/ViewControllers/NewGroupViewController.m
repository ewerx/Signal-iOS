//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "NewGroupViewController.h"
#import "AddToGroupViewController.h"
#import "AvatarViewHelper.h"
#import "OWSNavigationController.h"
#import "Signal-Swift.h"
#import "SignalApp.h"
#import <SignalCoreKit/NSDate+OWS.h>
#import <SignalCoreKit/Randomness.h>
#import <SignalMessaging/BlockListUIUtils.h>
#import <SignalMessaging/ContactTableViewCell.h>
#import <SignalMessaging/ContactsViewHelper.h>
#import <SignalMessaging/Environment.h>
#import <SignalMessaging/OWSContactsManager.h>
#import <SignalMessaging/OWSTableViewController.h>
#import <SignalMessaging/UIUtil.h>
#import <SignalMessaging/UIView+OWS.h>
#import <SignalMessaging/UIViewController+OWS.h>
#import <SignalServiceKit/NSString+SSK.h>
#import <SignalServiceKit/OWSMessageSender.h>
#import <SignalServiceKit/SignalAccount.h>
#import <SignalServiceKit/TSGroupModel.h>
#import <SignalServiceKit/TSGroupThread.h>
#import <SignalServiceKit/TSOutgoingMessage.h>

NS_ASSUME_NONNULL_BEGIN

@interface NewGroupViewController () <UIImagePickerControllerDelegate,
    UITextFieldDelegate,
    ContactsViewHelperDelegate,
    AvatarViewHelperDelegate,
    AddToGroupViewControllerDelegate,
    OWSTableViewControllerDelegate,
    UINavigationControllerDelegate,
    OWSNavigationView>

@property (nonatomic, readonly) OWSMessageSender *messageSender;
@property (nonatomic, readonly) ContactsViewHelper *contactsViewHelper;
@property (nonatomic, readonly) AvatarViewHelper *avatarViewHelper;

@property (nonatomic, readonly) OWSTableViewController *tableViewController;
@property (nonatomic, readonly) AvatarImageView *avatarView;
@property (nonatomic, readonly) UIImageView *cameraImageView;
@property (nonatomic, readonly) UITextField *groupNameTextField;

@property (nonatomic, readonly) NSData *groupId;

@property (nonatomic, nullable) UIImage *groupAvatar;
@property (nonatomic) NSMutableSet<SignalServiceAddress *> *memberRecipientAddresses;

@property (nonatomic) BOOL hasUnsavedChanges;
@property (nonatomic) BOOL hasAppeared;

@end

#pragma mark -

@implementation NewGroupViewController

- (instancetype)init
{
    self = [super init];
    if (!self) {
        return self;
    }

    [self commonInit];

    return self;
}

- (nullable instancetype)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    if (!self) {
        return self;
    }

    [self commonInit];

    return self;
}

- (void)commonInit
{
    _groupId = [Randomness generateRandomBytes:kGroupIdLength];

    _messageSender = SSKEnvironment.shared.messageSender;
    _contactsViewHelper = [[ContactsViewHelper alloc] initWithDelegate:self];
    _avatarViewHelper = [AvatarViewHelper new];
    _avatarViewHelper.delegate = self;

    self.memberRecipientAddresses = [NSMutableSet new];
}

#pragma mark - View Lifecycle

- (void)loadView
{
    [super loadView];

    self.title = [MessageStrings newGroupDefaultTitle];

    self.view.backgroundColor = Theme.backgroundColor;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"NEW_GROUP_CREATE_BUTTON",
                                                   @"The title for the 'create group' button.")
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(createGroup)
                       accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"create")];
    self.navigationItem.rightBarButtonItem.imageInsets = UIEdgeInsetsMake(0, -10, 0, 10);
    self.navigationItem.rightBarButtonItem.accessibilityLabel
        = NSLocalizedString(@"FINISH_GROUP_CREATION_LABEL", @"Accessibility label for finishing new group");

    // First section.

    UIView *firstSection = [self firstSectionHeader];
    [self.view addSubview:firstSection];
    [firstSection autoSetDimension:ALDimensionHeight toSize:100.f];
    [firstSection autoPinWidthToSuperview];
    [firstSection autoPinToTopLayoutGuideOfViewController:self withInset:0];

    _tableViewController = [OWSTableViewController new];
    _tableViewController.delegate = self;
    [self.view addSubview:self.tableViewController.view];
    [self.tableViewController.view autoPinEdgeToSuperviewSafeArea:ALEdgeLeading];
    [self.tableViewController.view autoPinEdgeToSuperviewSafeArea:ALEdgeTrailing];
    [_tableViewController.view autoPinEdge:ALEdgeTop toEdge:ALEdgeBottom ofView:firstSection];
    [self autoPinViewToBottomOfViewControllerOrKeyboard:self.tableViewController.view avoidNotch:NO];
    self.tableViewController.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableViewController.tableView.estimatedRowHeight = 60;

    [self updateTableContents];
}

- (UIView *)firstSectionHeader
{
    UIView *firstSectionHeader = [UIView new];
    firstSectionHeader.userInteractionEnabled = YES;
    [firstSectionHeader
        addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(headerWasTapped:)]];
    firstSectionHeader.backgroundColor = [Theme backgroundColor];
    UIView *threadInfoView = [UIView new];
    [firstSectionHeader addSubview:threadInfoView];
    [threadInfoView autoPinWidthToSuperviewWithMargin:16.f];
    [threadInfoView autoPinHeightToSuperviewWithMargin:16.f];

    AvatarImageView *avatarView = [AvatarImageView new];
    _avatarView = avatarView;

    [threadInfoView addSubview:avatarView];
    [avatarView autoVCenterInSuperview];
    [avatarView autoPinLeadingToSuperviewMargin];
    [avatarView autoSetDimension:ALDimensionWidth toSize:kLargeAvatarSize];
    [avatarView autoSetDimension:ALDimensionHeight toSize:kLargeAvatarSize];

    UIImage *cameraImage = [UIImage imageNamed:@"settings-avatar-camera"];
    UIImageView *cameraImageView = [[UIImageView alloc] initWithImage:cameraImage];
    [threadInfoView addSubview:cameraImageView];
    [cameraImageView autoPinTrailingToEdgeOfView:avatarView];
    [cameraImageView autoPinEdge:ALEdgeBottom toEdge:ALEdgeBottom ofView:avatarView];
    _cameraImageView = cameraImageView;

    [self updateAvatarView];

    [avatarView
        addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(avatarTouched:)]];
    avatarView.userInteractionEnabled = YES;
    SET_SUBVIEW_ACCESSIBILITY_IDENTIFIER(self, avatarView);

    UITextField *groupNameTextField = [OWSTextField new];
    _groupNameTextField = groupNameTextField;
    groupNameTextField.textColor = Theme.primaryColor;
    groupNameTextField.font = [UIFont ows_dynamicTypeTitle2Font];
    groupNameTextField.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:NSLocalizedString(@"NEW_GROUP_NAMEGROUP_REQUEST_DEFAULT",
                                                       @"Placeholder text for group name field")
                                        attributes:@{
                                            NSForegroundColorAttributeName : Theme.secondaryColor,
                                        }];
    groupNameTextField.delegate = self;
    [groupNameTextField addTarget:self
                           action:@selector(groupNameDidChange:)
                 forControlEvents:UIControlEventEditingChanged];
    [threadInfoView addSubview:groupNameTextField];
    [groupNameTextField autoVCenterInSuperview];
    [groupNameTextField autoPinTrailingToSuperviewMargin];
    [groupNameTextField autoPinLeadingToTrailingEdgeOfView:avatarView offset:16.f];
    SET_SUBVIEW_ACCESSIBILITY_IDENTIFIER(self, groupNameTextField);

    return firstSectionHeader;
}

- (void)headerWasTapped:(UIGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateRecognized) {
        [self.groupNameTextField becomeFirstResponder];
    }
}

- (void)avatarTouched:(UIGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateRecognized) {
        [self showChangeAvatarUI];
    }
}

#pragma mark - Table Contents

- (void)updateTableContents
{
    OWSTableContents *contents = [OWSTableContents new];

    __weak NewGroupViewController *weakSelf = self;
    ContactsViewHelper *contactsViewHelper = self.contactsViewHelper;

    NSArray<SignalAccount *> *signalAccounts = self.contactsViewHelper.signalAccounts;
    NSMutableSet *nonContactMemberRecipientAddresses = [self.memberRecipientAddresses mutableCopy];
    for (SignalAccount *signalAccount in signalAccounts) {
        [nonContactMemberRecipientAddresses removeObject:signalAccount.recipientAddress];
    }

    // Non-contact Members

    if (nonContactMemberRecipientAddresses.count > 0 || signalAccounts.count < 1) {

        OWSTableSection *nonContactsSection = [OWSTableSection new];
        nonContactsSection.headerTitle = NSLocalizedString(
            @"NEW_GROUP_NON_CONTACTS_SECTION_TITLE", @"a title for the non-contacts section of the 'new group' view.");

        [nonContactsSection addItem:[self createAddNonContactItem]];

        for (SignalServiceAddress *address in
            [nonContactMemberRecipientAddresses.allObjects sortedArrayUsingSelector:@selector(compare:)]) {

            [nonContactsSection
                addItem:[OWSTableItem
                            itemWithCustomCellBlock:^{
                                NewGroupViewController *strongSelf = weakSelf;
                                OWSCAssertDebug(strongSelf);

                                ContactTableViewCell *cell = [ContactTableViewCell new];
                                BOOL isCurrentMember = [strongSelf.memberRecipientAddresses containsObject:address];
                                BOOL isBlocked = [contactsViewHelper isSignalServiceAddressBlocked:address];
                                if (isCurrentMember) {
                                    // In the "contacts" section, we label members as such when editing an existing
                                    // group.
                                    cell.accessoryMessage = NSLocalizedString(@"NEW_GROUP_MEMBER_LABEL",
                                        @"An indicator that a user is a member of the new group.");
                                } else if (isBlocked) {
                                    cell.accessoryMessage = NSLocalizedString(
                                        @"CONTACT_CELL_IS_BLOCKED", @"An indicator that a contact has been blocked.");
                                }
                                [cell configureWithRecipientAddress:address];

                                NSString *cellName =
                                    [NSString stringWithFormat:@"non_signal_contact.%@", address.stringForDisplay];
                                cell.accessibilityIdentifier
                                    = ACCESSIBILITY_IDENTIFIER_WITH_NAME(NewGroupViewController, cellName);

                                return cell;
                            }
                            customRowHeight:UITableViewAutomaticDimension
                            actionBlock:^{
                                BOOL isCurrentMember = [weakSelf.memberRecipientAddresses containsObject:address];
                                BOOL isBlocked = [contactsViewHelper isSignalServiceAddressBlocked:address];
                                if (isCurrentMember) {
                                    [weakSelf removeRecipientAddress:address];
                                } else if (isBlocked) {
                                    [BlockListUIUtils showUnblockAddressActionSheet:address
                                                                 fromViewController:weakSelf
                                                                    blockingManager:contactsViewHelper.blockingManager
                                                                    contactsManager:contactsViewHelper.contactsManager
                                                                    completionBlock:^(BOOL isStillBlocked) {
                                                                        if (!isStillBlocked) {
                                                                            [weakSelf addRecipientAddress:address];
                                                                        }
                                                                    }];
                                } else {

                                    BOOL didShowSNAlert = [SafetyNumberConfirmationAlert
                                        presentAlertIfNecessaryWithAddress:address
                                                          confirmationText:NSLocalizedString(
                                                                               @"SAFETY_NUMBER_CHANGED_CONFIRM_"
                                                                               @"ADD_TO_GROUP_ACTION",
                                                                               @"button title to confirm adding "
                                                                               @"a recipient to a group when "
                                                                               @"their safety "
                                                                               @"number has recently changed")
                                                           contactsManager:contactsViewHelper.contactsManager
                                                                completion:^(BOOL didConfirmIdentity) {
                                                                    if (didConfirmIdentity) {
                                                                        [weakSelf addRecipientAddress:address];
                                                                    }
                                                                }];
                                    if (didShowSNAlert) {
                                        return;
                                    }


                                    [weakSelf addRecipientAddress:address];
                                }
                            }]];
        }
        [contents addSection:nonContactsSection];
    }

    // Contacts

    OWSTableSection *signalAccountSection = [OWSTableSection new];
    signalAccountSection.headerTitle = NSLocalizedString(
        @"EDIT_GROUP_CONTACTS_SECTION_TITLE", @"a title for the contacts section of the 'new/update group' view.");
    if (signalAccounts.count > 0) {

        if (nonContactMemberRecipientAddresses.count < 1) {
            // If the group contains any non-contacts or has not contacts,
            // the "add non-contact user" will show up in the previous section
            // of the table. However, it's more attractive to hide that section
            // for the common case where people want to create a group from just
            // their contacts.  Therefore, when that section is hidden, we want
            // to allow people to add non-contacts.
            [signalAccountSection addItem:[self createAddNonContactItem]];
        }

        for (SignalAccount *signalAccount in signalAccounts) {
            [signalAccountSection
                addItem:[OWSTableItem
                            itemWithCustomCellBlock:^{
                                NewGroupViewController *strongSelf = weakSelf;
                                OWSCAssertDebug(strongSelf);

                                ContactTableViewCell *cell = [ContactTableViewCell new];

                                SignalServiceAddress *address = signalAccount.recipientAddress;
                                BOOL isCurrentMember = [strongSelf.memberRecipientAddresses containsObject:address];
                                BOOL isBlocked = [contactsViewHelper isSignalServiceAddressBlocked:address];
                                if (isCurrentMember) {
                                    // In the "contacts" section, we label members as such when editing an existing
                                    // group.
                                    cell.accessoryMessage = NSLocalizedString(@"NEW_GROUP_MEMBER_LABEL",
                                        @"An indicator that a user is a member of the new group.");
                                } else if (isBlocked) {
                                    cell.accessoryMessage = NSLocalizedString(
                                        @"CONTACT_CELL_IS_BLOCKED", @"An indicator that a contact has been blocked.");
                                }

                                [cell configureWithRecipientAddress:signalAccount.recipientAddress];

                                NSString *cellName = [NSString
                                    stringWithFormat:@"signal_contact.%@", address.phoneNumber ?: address.uuidString];
                                cell.accessibilityIdentifier
                                    = ACCESSIBILITY_IDENTIFIER_WITH_NAME(NewGroupViewController, cellName);

                                return cell;
                            }
                            customRowHeight:UITableViewAutomaticDimension
                            actionBlock:^{
                                SignalServiceAddress *address = signalAccount.recipientAddress;
                                BOOL isCurrentMember = [weakSelf.memberRecipientAddresses containsObject:address];
                                BOOL isBlocked = [contactsViewHelper isSignalServiceAddressBlocked:address];
                                if (isCurrentMember) {
                                    [weakSelf removeRecipientAddress:address];
                                } else if (isBlocked) {
                                    [BlockListUIUtils
                                        showUnblockSignalAccountActionSheet:signalAccount
                                                         fromViewController:weakSelf
                                                            blockingManager:contactsViewHelper.blockingManager
                                                            contactsManager:contactsViewHelper.contactsManager
                                                            completionBlock:^(BOOL isStillBlocked) {
                                                                if (!isStillBlocked) {
                                                                    [weakSelf addRecipientAddress:address];
                                                                }
                                                            }];
                                } else {
                                    BOOL didShowSNAlert = [SafetyNumberConfirmationAlert
                                        presentAlertIfNecessaryWithAddress:address
                                                          confirmationText:NSLocalizedString(
                                                                               @"SAFETY_NUMBER_CHANGED_CONFIRM_"
                                                                               @"ADD_TO_GROUP_ACTION",
                                                                               @"button title to confirm adding "
                                                                               @"a recipient to a group when "
                                                                               @"their safety "
                                                                               @"number has recently changed")
                                                           contactsManager:contactsViewHelper.contactsManager
                                                                completion:^(BOOL didConfirmIdentity) {
                                                                    if (didConfirmIdentity) {
                                                                        [weakSelf addRecipientAddress:address];
                                                                    }
                                                                }];
                                    if (didShowSNAlert) {
                                        return;
                                    }

                                    [weakSelf addRecipientAddress:address];
                                }
                            }]];
        }
    } else {
        [signalAccountSection
            addItem:[OWSTableItem
                        softCenterLabelItemWithText:NSLocalizedString(@"SETTINGS_BLOCK_LIST_NO_CONTACTS",
                                                        @"A label that indicates the user has no Signal contacts.")]];
    }
    [contents addSection:signalAccountSection];

    self.tableViewController.contents = contents;
}

- (OWSTableItem *)createAddNonContactItem
{
    __weak NewGroupViewController *weakSelf = self;
    return [OWSTableItem
         disclosureItemWithText:NSLocalizedString(@"NEW_GROUP_ADD_NON_CONTACT",
                                    @"A label for the cell that lets you add a new non-contact member to a group.")
        accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(NewGroupViewController, @"add_non_contact")
                customRowHeight:UITableViewAutomaticDimension
                    actionBlock:^{
                        AddToGroupViewController *viewController = [AddToGroupViewController new];
                        viewController.addToGroupDelegate = weakSelf;
                        viewController.hideContacts = YES;
                        [weakSelf.navigationController pushViewController:viewController animated:YES];
                    }];
}

- (void)removeRecipientAddress:(SignalServiceAddress *)address
{
    OWSAssertDebug(address.isValid);

    [self.memberRecipientAddresses removeObject:address];
    [self updateTableContents];
}

- (void)addRecipientAddress:(SignalServiceAddress *)address
{
    OWSAssertDebug(address.isValid);

    [self.memberRecipientAddresses addObject:address];
    self.hasUnsavedChanges = YES;
    [self updateTableContents];
}

#pragma mark - Methods

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    if (!self.hasAppeared) {
        [self.groupNameTextField becomeFirstResponder];
        self.hasAppeared = YES;
    }
}

#pragma mark - Actions

- (void)createGroup
{
    OWSAssertIsOnMainThread();

    [self.groupNameTextField acceptAutocorrectSuggestion];

    TSGroupModel *model = [self makeGroup];

    __block TSGroupThread *thread;
    [OWSPrimaryStorage.dbReadWriteConnection
        readWriteWithBlock:^(YapDatabaseReadWriteTransaction *_Nonnull transaction) {
            thread = [TSGroupThread getOrCreateThreadWithGroupModel:model transaction:transaction];
        }];
    OWSAssertDebug(thread);
    
    [OWSProfileManager.sharedManager addThreadToProfileWhitelist:thread];

    void (^successHandler)(void) = ^{
        OWSLogError(@"Group creation successful.");

        dispatch_async(dispatch_get_main_queue(), ^{
            [SignalApp.sharedApp presentConversationForThread:thread action:ConversationViewActionCompose animated:NO];
            [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
        });
    };

    void (^failureHandler)(NSError *error) = ^(NSError *error) {
        OWSLogError(@"Group creation failed: %@", error);

        // Add an error message to the new group indicating
        // that group creation didn't succeed.
        // MJK TODO should be safe to remove senderTimestamp and just save immediately
        TSErrorMessage *errorMessage = [[TSErrorMessage alloc] initWithTimestamp:[NSDate ows_millisecondTimeStamp]
                                                                        inThread:thread
                                                               failedMessageType:TSErrorMessageGroupCreationFailed];
        [errorMessage save];

        dispatch_async(dispatch_get_main_queue(), ^{
            [SignalApp.sharedApp presentConversationForThread:thread action:ConversationViewActionCompose animated:NO];
            [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
        });
    };

    [ModalActivityIndicatorViewController
        presentFromViewController:self
                        canCancel:NO
                  backgroundBlock:^(ModalActivityIndicatorViewController *modalActivityIndicator) {
                      TSOutgoingMessage *message = [TSOutgoingMessage outgoingMessageInThread:thread
                                                                             groupMetaMessage:TSGroupMetaMessageNew
                                                                             expiresInSeconds:0];

                      [message updateWithCustomMessage:NSLocalizedString(@"GROUP_CREATED", nil)];

                      dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                          if (model.groupImage) {
                              NSData *data = UIImagePNGRepresentation(model.groupImage);
                              DataSource *_Nullable dataSource =
                                  [DataSourceValue dataSourceWithData:data fileExtension:@"png"];
                              // CLEANUP DURABLE - Replace with a durable operation e.g. `GroupCreateJob`, which creates
                              // an error in the thread if group creation fails
                              [self.messageSender sendTemporaryAttachment:dataSource
                                                              contentType:OWSMimeTypeImagePng
                                                                inMessage:message
                                                                  success:successHandler
                                                                  failure:failureHandler];
                          } else {
                              // CLEANUP DURABLE - Replace with a durable operation e.g. `GroupCreateJob`, which creates
                              // an error in the thread if group creation fails
                              [self.messageSender sendMessage:message success:successHandler failure:failureHandler];
                          }
                      });
                  }];
}

- (TSGroupModel *)makeGroup
{
    NSString *groupName = [self.groupNameTextField.text ows_stripped];
    NSMutableArray<SignalServiceAddress *> *recipientAddressess =
        [self.memberRecipientAddresses.allObjects mutableCopy];
    [recipientAddressess addObject:[self.contactsViewHelper localAddress]];
    return [[TSGroupModel alloc] initWithTitle:groupName
                                       members:recipientAddressess
                                         image:self.groupAvatar
                                       groupId:self.groupId];
}

#pragma mark - Group Avatar

- (void)showChangeAvatarUI
{
    [self.avatarViewHelper showChangeAvatarUI];
}

- (void)setGroupAvatar:(nullable UIImage *)groupAvatar
{
    OWSAssertIsOnMainThread();

    _groupAvatar = groupAvatar;

    self.hasUnsavedChanges = YES;

    [self updateAvatarView];
}

- (void)updateAvatarView
{
    UIImage *_Nullable groupAvatar = self.groupAvatar;
    self.cameraImageView.hidden = groupAvatar != nil;

    if (!groupAvatar) {
        NSString *conversationColorName = [TSGroupThread defaultConversationColorNameForGroupId:self.groupId];
        groupAvatar = [OWSGroupAvatarBuilder defaultAvatarForGroupId:self.groupId
                                               conversationColorName:conversationColorName
                                                            diameter:kLargeAvatarSize];
    }

    self.avatarView.image = groupAvatar;
}

#pragma mark - Event Handling

- (void)backButtonPressed
{
    [self.groupNameTextField resignFirstResponder];

    if (!self.hasUnsavedChanges) {
        // If user made no changes, return to conversation settings view.
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:
            NSLocalizedString(@"NEW_GROUP_VIEW_UNSAVED_CHANGES_TITLE",
                @"The alert title if user tries to exit the new group view without saving changes.")
                         message:
                             NSLocalizedString(@"NEW_GROUP_VIEW_UNSAVED_CHANGES_MESSAGE",
                                 @"The alert message if user tries to exit the new group view without saving changes.")
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert
        addAction:[UIAlertAction actionWithTitle:NSLocalizedString(@"ALERT_DISCARD_BUTTON",
                                                     @"The label for the 'discard' button in alerts and action sheets.")
                         accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"discard")
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *action) {
                                             [self.navigationController popViewControllerAnimated:YES];
                                         }]];
    [alert addAction:[OWSAlerts cancelAction]];
    [self presentAlert:alert];
}

- (void)groupNameDidChange:(id)sender
{
    self.hasUnsavedChanges = YES;
}

#pragma mark - Text Field Delegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField
{
    [self.groupNameTextField resignFirstResponder];
    return NO;
}

#pragma mark - OWSTableViewControllerDelegate

- (void)tableViewWillBeginDragging
{
    [self.groupNameTextField resignFirstResponder];
}

#pragma mark - ContactsViewHelperDelegate

- (void)contactsViewHelperDidUpdateContacts
{
    [self updateTableContents];
}

- (BOOL)shouldHideLocalNumber
{
    return YES;
}

#pragma mark - AvatarViewHelperDelegate

- (nullable NSString *)avatarActionSheetTitle
{
    return NSLocalizedString(
        @"NEW_GROUP_ADD_PHOTO_ACTION", @"Action Sheet title prompting the user for a group avatar");
}

- (void)avatarDidChange:(UIImage *)image
{
    OWSAssertIsOnMainThread();
    OWSAssertDebug(image);

    self.groupAvatar = image;
}

- (UIViewController *)fromViewController
{
    return self;
}

- (BOOL)hasClearAvatarAction
{
    return NO;
}

#pragma mark - AddToGroupViewControllerDelegate

- (void)recipientAddressWasAdded:(SignalServiceAddress *)address
{
    [self addRecipientAddress:address];
}

- (BOOL)isRecipientGroupMember:(SignalServiceAddress *)address
{
    OWSAssertDebug(address.isValid);

    return [self.memberRecipientAddresses containsObject:address];
}

#pragma mark - OWSNavigationView

- (BOOL)shouldCancelNavigationBack
{
    BOOL result = self.hasUnsavedChanges;
    if (self.hasUnsavedChanges) {
        [self backButtonPressed];
    }
    return result;
}

@end

NS_ASSUME_NONNULL_END
