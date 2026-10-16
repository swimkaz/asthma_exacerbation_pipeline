import pandas as pd
import numpy as np
import matplotlib.pyplot as plt

from matplotlib.patches import Patch
from xgboost import XGBClassifier
from sklearn.model_selection import train_test_split
from sklearn.metrics import (
    roc_auc_score,
    average_precision_score,
    classification_report,
    confusion_matrix,
    roc_curve,
    precision_recall_curve,
    brier_score_loss
)

# =========================
# LOAD CLINICAL DATA
# =========================

df = pd.read_csv("combinedcsv_2.csv")
df = df.dropna(subset=["PatientID", "PatientAgeAtIndex"])
df["PatientID"] = df["PatientID"].astype(str)

# =========================
# DEFINE OUTCOME
# =========================

outcome_col = "y_future_exacerbation"

if df[outcome_col].dtype == "object":
    df[outcome_col] = df[outcome_col].map({
        "No": 0, "Yes": 1,
        "False": 0, "True": 1,
        "control": 0, "case": 1
    })

df = df.dropna(subset=[outcome_col])

# =========================
# REMOVE NON-FEATURE COLUMNS
# =========================

drop_cols = [
    "PatientID", outcome_col, "index", "IID", "FID",
    "Bank_sample_id", "PRS", "DiagnosisName", "DiagnosisCode",
    "EncounterID", "EncounterDate", "IndexDate"
]
drop_cols = [c for c in drop_cols if c in df.columns]

X = df.drop(columns=drop_cols)
y = df[outcome_col].astype(int)

# =========================
# KEEP ONLY NUMERIC FEATURES
# =========================

X = X.select_dtypes(include=[np.number])
X = X.astype(np.float32)

print("=" * 60)
print("CLINICAL-ONLY XGBOOST")
print("=" * 60)
print("Final X shape:", X.shape)
print("PRS included?", "PRS" in X.columns)
print("\nOutcome counts:")
print(y.value_counts())
print("\nOutcome prevalence:", y.mean())
print("\nNumber of features:", X.shape[1])

# =========================
# TRAIN / TEST SPLIT
# =========================

X_train, X_test, y_train, y_test = train_test_split(
    X, y, test_size=0.20, stratify=y, random_state=42
)

print("\nTraining patients:", len(X_train))
print("Test patients:", len(X_test))

# =========================
# CLASS IMBALANCE
# =========================

neg = (y_train == 0).sum()
pos = (y_train == 1).sum()
scale_pos_weight = neg / pos

print("\nscale_pos_weight:", scale_pos_weight)

# =========================
# XGBOOST MODEL
# =========================

xgb_model = XGBClassifier(
    n_estimators=100,
    max_depth=3,
    learning_rate=0.05,
    subsample=0.8,
    colsample_bytree=0.8,
    objective="binary:logistic",
    eval_metric="auc",
    scale_pos_weight=scale_pos_weight,
    tree_method="hist",
    random_state=42,
    n_jobs=2
)

xgb_model.fit(X_train, y_train)

# =========================
# PREDICTIONS
# =========================

threshold = 0.50
y_prob = xgb_model.predict_proba(X_test)[:, 1]
y_pred = (y_prob >= threshold).astype(int)

# =========================
# METRICS
# =========================

auc = roc_auc_score(y_test, y_prob)
auprc = average_precision_score(y_test, y_prob)
brier = brier_score_loss(y_test, y_prob)

cm = confusion_matrix(y_test, y_pred)
tn, fp, fn, tp = cm.ravel()

sensitivity = tp / (tp + fn) if (tp + fn) > 0 else 0
specificity = tn / (tn + fp) if (tn + fp) > 0 else 0
ppv = tp / (tp + fp) if (tp + fp) > 0 else 0
npv = tn / (tn + fn) if (tn + fn) > 0 else 0

print("\n" + "=" * 60)
print("XGBOOST PERFORMANCE ON TEST SET")
print("=" * 60)
print(f"AUROC:       {auc:.4f}")
print(f"AUPRC:       {auprc:.4f}")
print(f"Brier Score: {brier:.4f}")
print(f"Baseline AUPRC (test prevalence): {y_test.mean():.4f}")
print(f"\nAt threshold = {threshold:.2f}:")
print(f"Sensitivity / Recall: {sensitivity:.4f}")
print(f"Specificity:          {specificity:.4f}")
print(f"PPV / Precision:      {ppv:.4f}")
print(f"NPV:                  {npv:.4f}")

print("\nConfusion Matrix:")
print("                 Predicted")
print("                 No      Yes")
print(f"Actual No     {tn:6d}  {fp:6d}")
print(f"Actual Yes    {fn:6d}  {tp:6d}")

print("\nClassification Report:")
print(classification_report(y_test, y_pred, digits=4))

# =========================
# VISUALIZATIONS
# =========================

fig, axes = plt.subplots(2, 2, figsize=(14, 12))

# ROC curve
fpr, tpr, _ = roc_curve(y_test, y_prob)
ax1 = axes[0, 0]
ax1.plot(fpr, tpr, linewidth=2, label=f"AUROC = {auc:.4f}")
ax1.plot([0, 1], [0, 1], linestyle="--", linewidth=1,
         label="Random (AUROC = 0.50)")
ax1.set_xlabel("False Positive Rate", fontsize=12)
ax1.set_ylabel("True Positive Rate", fontsize=12)
ax1.set_title("ROC Curve - Clinical XGBoost", fontsize=14, fontweight="bold")
ax1.legend(fontsize=11)
ax1.grid(True, alpha=0.3)

# Precision-recall curve
precision, recall, _ = precision_recall_curve(y_test, y_prob)
ax2 = axes[0, 1]
ax2.plot(recall, precision, linewidth=2, label=f"AUPRC = {auprc:.4f}")
ax2.axhline(y=y_test.mean(), linestyle="--", linewidth=1,
            label=f"Baseline prevalence = {y_test.mean():.3f}")
ax2.set_xlabel("Recall (Sensitivity)", fontsize=12)
ax2.set_ylabel("Precision (PPV)", fontsize=12)
ax2.set_title("Precision-Recall Curve", fontsize=14, fontweight="bold")
ax2.legend(fontsize=11)
ax2.grid(True, alpha=0.3)

# Confusion matrix
ax3 = axes[1, 0]
im = ax3.imshow(cm)
ax3.set_xlabel("Predicted Label", fontsize=12)
ax3.set_ylabel("True Label", fontsize=12)
ax3.set_title(f"Confusion Matrix (threshold = {threshold:.2f})",
              fontsize=14, fontweight="bold")
ax3.set_xticks([0, 1])
ax3.set_yticks([0, 1])
ax3.set_xticklabels(["No Exacerbation", "Exacerbation"])
ax3.set_yticklabels(["No Exacerbation", "Exacerbation"])

for i in range(cm.shape[0]):
    for j in range(cm.shape[1]):
        ax3.text(j, i, cm[i, j], ha="center", va="center", fontsize=14)

fig.colorbar(im, ax=ax3, fraction=0.046, pad=0.04)

# Predicted probability distribution
ax4 = axes[1, 1]
y_test_array = np.asarray(y_test)

ax4.hist(y_prob[y_test_array == 0], bins=50, alpha=0.6,
         density=True, color="blue")
ax4.hist(y_prob[y_test_array == 1], bins=50, alpha=0.6,
         density=True, color="red")
ax4.axvline(x=threshold, color="black", linestyle="--", linewidth=2)

ax4.set_xlabel("Predicted Probability", fontsize=12)
ax4.set_ylabel("Density", fontsize=12)
ax4.set_title("Distribution of Predicted Probabilities",
              fontsize=14, fontweight="bold")

legend_elements = [
    Patch(facecolor="blue", alpha=0.6, label="No Exacerbation"),
    Patch(facecolor="red", alpha=0.6, label="Exacerbation"),
    Patch(facecolor="purple", alpha=0.6, label="Overlap")
]
ax4.legend(handles=legend_elements, fontsize=11)
ax4.grid(True, alpha=0.3)

plt.tight_layout()
plt.show()

# =========================
# FEATURE IMPORTANCE
# =========================

importance_df = pd.DataFrame({
    "Feature": X.columns,
    "Importance": xgb_model.feature_importances_
}).sort_values("Importance", ascending=False)

print("\nTop 20 XGBoost Features:")
print(importance_df.head(20))

top20 = importance_df.head(20)

plt.figure(figsize=(10, 8))
plt.barh(top20["Feature"][::-1], top20["Importance"][::-1])
plt.xlabel("Feature Importance")
plt.title("Top 20 Clinical XGBoost Features")
plt.tight_layout()
plt.show()
