#import "SL.h"
#import "NFFocus.h"

typedef NS_ENUM(NSInteger, SLSection) { SLToday, SLSettingsSection, SLDetection, SLHistory, SLSectionCount };

/// Journal des écrans vus, avec partage du fichier.
@interface SLLogController : UIViewController
@end

@implementation SLLogController {
    UITextView *_text;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Journal";
    _text = [UITextView new];
    _text.editable = NO;
    _text.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _text.text = SLCore.shared.logText;
    _text.frame = self.view.bounds;
    _text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_text];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                                                                                           target:self action:@selector(share:)];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_text.text.length) [_text scrollRangeToVisible:NSMakeRange(_text.text.length - 1, 1)];
}
- (void)share:(UIBarButtonItem *)sender {
    NSURL *url = [NSURL fileURLWithPath:SLCore.shared.logPath];
    NSArray *items = [NSFileManager.defaultManager fileExistsAtPath:url.path] ? @[url] : @[_text.text ?: @""];
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
    a.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:a animated:YES completion:nil];
}
@end

@implementation SLSettingsController {
    NSTimer *_timer;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Shorts Limiter";
    self.tableView.backgroundColor = [UIColor colorWithRed:15 / 255.0 green:15 / 255.0 blue:15 / 255.0 alpha:1];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                           target:self action:@selector(close)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
    _timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refreshToday) userInfo:nil repeats:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_timer invalidate];
    _timer = nil;
}

- (void)refreshToday {
    [UIView performWithoutAnimation:^{
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:SLToday] withRowAnimation:UITableViewRowAnimationNone];
    }];
}

- (void)close {
    [_timer invalidate];
    void (^done)(void) = self.onClose;
    [self.navigationController dismissViewControllerAnimated:YES completion:done];
}

- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    [_timer invalidate];
    if (self.onClose) self.onClose();
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return SLSectionCount; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case SLToday: return 4;
        case SLSettingsSection: return 4;
        case SLDetection: return 7;
        default: return MAX(1, (NSInteger)SLCore.shared.history.count);
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case SLToday: return @"Aujourd'hui";
        case SLSettingsSection: return @"Réglages";
        case SLDetection: return @"Détection des Shorts";
        default: return @"Jours précédents";
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    SLCore *c = SLCore.shared;
    switch (section) {
        case SLSettingsSection:
            return @"Le temps passé sur les Shorts (app au premier plan) est cumulé jusqu'à la limite, puis les Shorts sont bloqués pendant la durée choisie. Mode focus NoteFlow : pendant un focus, YouTube entier est bloqué. Une nouvelle durée de blocage s'applique au prochain blocage. Appui long à trois doigts n'importe où pour rouvrir cet écran.";
        case SLDetection:
            return [NSString stringWithFormat:@"Un écran est reconnu comme Shorts si le nom de sa classe contient un des noms recherchés (sans contenir un nom exclu) et qu'il occupe au moins la moitié de l'écran. Le journal liste les écrans vus : ouvre un Short, puis regarde le journal pour ajuster les noms.\nÉcran Shorts actuel : %@\nShortLimiter %s", c.matchedName ?: @"aucun", SL_VERSION];
        default: return nil;
    }
}

- (UITableViewCell *)valueCell:(NSString *)title value:(NSString *)value {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = value;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)ip {
    SLCore *c = SLCore.shared;
    NSDictionary *today = c.today;
    switch (ip.section) {
        case SLToday:
            switch (ip.row) {
                case 0: return [self valueCell:@"Temps sur les Shorts" value:SLFormat([today[@"seconds"] doubleValue])];
                case 1: return [self valueCell:@"Ouvertures des Shorts" value:[today[@"entries"] stringValue]];
                case 2: return [self valueCell:@"Blocages" value:[today[@"blocks"] stringValue]];
                default: {
                    UITableViewCell *cell = c.isBlocked
                        ? [self valueCell:@"Shorts bloqués encore" value:SLFormat(c.remainingBlock)]
                        : [self valueCell:@"Temps restant avant blocage" value:c.remainingBeforeBlock < 0 ? @"Aucune limite" : SLFormat(c.remainingBeforeBlock)];
                    cell.detailTextLabel.textColor = c.isBlocked ? UIColor.systemRedColor : UIColor.systemGreenColor;
                    return cell;
                }
            }
        case SLSettingsSection:
            switch (ip.row) {
                case 0: return [self stepperCell:@"Limite" value:c.limitMinutes min:1 max:180 step:1 tag:0];
                case 1: return [self stepperCell:@"Durée du blocage" value:c.blockMinutes min:5 max:720 step:5 tag:1];
                case 2: return [self switchCell:@"Compteur pendant les Shorts" on:c.showCounter action:@selector(toggleCounter:)];
                default: {
                    // Blocage de toute l'app pendant un focus NoteFlow (shared/NFFocus.m)
                    UITableViewCell *cell = [self valueCell:@"Mode focus NoteFlow" value:NFFocusStatus()];
                    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    return cell;
                }
            }
        case SLDetection:
            switch (ip.row) {
                case 0: return [self editCell:@"Noms recherchés" value:c.includeNames];
                case 1: return [self editCell:@"Noms exclus" value:c.excludeNames];
                case 2: return [self editCell:@"Barre d'onglets" value:c.exitNames];
                case 3: return [self switchCell:@"Journal des écrans" on:c.logEnabled action:@selector(toggleLog:)];
                case 4: return [self actionCell:@"Voir le journal" destructive:NO];
                case 5: return [self actionCell:@"Effacer le journal" destructive:YES];
                default: return [self actionCell:@"Noms par défaut" destructive:NO];
            }
        default: {
            NSArray *h = c.history;
            if (!h.count) return [self valueCell:@"Aucun jour enregistré" value:@""];
            NSDictionary *d = h[ip.row];
            NSString *v = [NSString stringWithFormat:@"%@ · %@ blocage(s)", SLFormat([d[@"seconds"] doubleValue]), d[@"blocks"]];
            return [self valueCell:d[@"day"] value:v];
        }
    }
}

- (UITableViewCell *)stepperCell:(NSString *)title value:(NSInteger)value min:(double)min max:(double)max step:(double)step tag:(NSInteger)tag {
    UITableViewCell *cell = [self valueCell:title value:[NSString stringWithFormat:@"%ld min", (long)value]];
    UIStepper *s = [UIStepper new];
    s.minimumValue = min;
    s.maximumValue = max;
    s.stepValue = step;
    s.value = value;
    s.tag = tag;
    [s addTarget:self action:@selector(stepped:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = s;
    cell.textLabel.text = [NSString stringWithFormat:@"%@ : %ld min", title, (long)value];
    cell.detailTextLabel.text = nil;
    return cell;
}

- (UITableViewCell *)switchCell:(NSString *)title on:(BOOL)on action:(SEL)action {
    UITableViewCell *cell = [self valueCell:title value:nil];
    UISwitch *sw = [UISwitch new];
    sw.on = on;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (UITableViewCell *)editCell:(NSString *)title value:(NSString *)value {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = value.length ? value : @"(vide)";
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (UITableViewCell *)actionCell:(NSString *)title destructive:(BOOL)destructive {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = title;
    cell.textLabel.textColor = destructive ? UIColor.systemRedColor : self.view.tintColor;
    return cell;
}

#pragma mark Actions

- (void)stepped:(UIStepper *)s {
    if (s.tag == 0) SLCore.shared.limitMinutes = (NSInteger)s.value;
    else SLCore.shared.blockMinutes = (NSInteger)s.value;
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:s.tag inSection:SLSettingsSection]];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ : %ld min", s.tag == 0 ? @"Limite" : @"Durée du blocage", (long)s.value];
}

- (void)toggleCounter:(UISwitch *)sw { SLCore.shared.showCounter = sw.on; }
- (void)toggleLog:(UISwitch *)sw { SLCore.shared.logEnabled = sw.on; }

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tableView deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == SLSettingsSection && ip.row == 3) { NFFocusPresentSettings(self); return; }
    if (ip.section != SLDetection) return;
    SLCore *c = SLCore.shared;
    switch (ip.row) {
        case 0: { [self editList:@"Noms recherchés" value:c.includeNames save:^(NSString *v) { c.includeNames = v; }]; break; }
        case 1: { [self editList:@"Noms exclus" value:c.excludeNames save:^(NSString *v) { c.excludeNames = v; }]; break; }
        case 2: { [self editList:@"Barre d'onglets" value:c.exitNames save:^(NSString *v) { c.exitNames = v; }]; break; }
        case 4: { [self.navigationController pushViewController:[SLLogController new] animated:YES]; break; }
        case 5: { [c clearLog]; break; }
        case 6: { [c resetDetectionNames]; [tableView reloadData]; break; }
        default: break;
    }
}

- (void)editList:(NSString *)title value:(NSString *)value save:(void (^)(NSString *))save {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title
                                                               message:@"Morceaux de noms de classes, séparés par des virgules (majuscules indifférentes)."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = value;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Annuler" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = a;
    [a addAction:[UIAlertAction actionWithTitle:@"Enregistrer" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        save(weakAlert.textFields.firstObject.text ?: @"");
        [self.tableView reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
